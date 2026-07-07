import Foundation

struct TokenUsage: Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
}

struct ModelPricing: Sendable {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheCreationPerMillion: Double
    let cacheReadPerMillion: Double

    func cost(for usage: TokenUsage) -> Double {
        (Double(usage.inputTokens) * inputPerMillion
            + Double(usage.outputTokens) * outputPerMillion
            + Double(usage.cacheCreationTokens) * cacheCreationPerMillion
            + Double(usage.cacheReadTokens) * cacheReadPerMillion) / 1_000_000.0
    }
}

struct SessionCost: Sendable, Equatable {
    let sessionID: String
    let projectPath: String
    let totalCost: Double
    let totalUsage: TokenUsage
    let model: String
    let messageCount: Int
    let firstMessageAt: Date?
    let lastMessageAt: Date?
}

struct ProjectCost: Sendable {
    let projectName: String
    let todayCost: Double
    let weekCost: Double
    let todaySessions: Int
    let weekSessions: Int
}

struct CostSnapshot: Sendable {
    let activeSessions: [SessionCost]
    let todayCost: Double
    let weekCost: Double
    let todaySessions: Int
    let weekSessions: Int
    let projectCosts: [ProjectCost]
}

@MainActor
final class SessionCostEstimator {
    // Rates are per 1M tokens, Anthropic standard API. Cache-write is the 5-minute
    // TTL rate (1.25x input); cache-read is 0.1x input.
    // Source: https://claude.com/pricing (verified 2026-07).

    /// Fable 5 — most capable widely released model ($10 in / $50 out).
    /// Also covers Mythos 5, which shares Fable 5's pricing.
    private static let fablePricing = ModelPricing(
        inputPerMillion: 10.0, outputPerMillion: 50.0,
        cacheCreationPerMillion: 12.50, cacheReadPerMillion: 1.00
    )
    /// Opus 4.5 / 4.6 / 4.7 / 4.8 — current Opus tier ($5 in / $25 out).
    private static let opusCurrentPricing = ModelPricing(
        inputPerMillion: 5.0, outputPerMillion: 25.0,
        cacheCreationPerMillion: 6.25, cacheReadPerMillion: 0.50
    )
    /// Opus 4, 4.1, Opus 3 (legacy $15 in / $75 out).
    private static let opusLegacyPricing = ModelPricing(
        inputPerMillion: 15.0, outputPerMillion: 75.0,
        cacheCreationPerMillion: 18.75, cacheReadPerMillion: 1.50
    )
    /// Sonnet 4.x / Sonnet 5 ($3 in / $15 out). Sonnet 5 carries a reduced
    /// intro rate ($2 / $10) through 2026-08-31; standard rates are used here to
    /// stay aligned with JSONL cost parsers (ccusage) and permanent pricing.
    private static let sonnetPricing = ModelPricing(
        inputPerMillion: 3.0, outputPerMillion: 15.0,
        cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30
    )
    private static let haiku45Pricing = ModelPricing(
        inputPerMillion: 1.0, outputPerMillion: 5.0,
        cacheCreationPerMillion: 1.25, cacheReadPerMillion: 0.10
    )
    private static let haiku35Pricing = ModelPricing(
        inputPerMillion: 0.80, outputPerMillion: 4.0,
        cacheCreationPerMillion: 1.0, cacheReadPerMillion: 0.08
    )

    private static let pricing: [String: ModelPricing] = [
        "claude-fable-5": fablePricing,
        "claude-mythos-5": fablePricing,
        "claude-opus-4-8": opusCurrentPricing,
        "claude-opus-4-7": opusCurrentPricing,
        "claude-opus-4-6": opusCurrentPricing,
        "claude-opus-4-5": opusCurrentPricing,
        "claude-opus-4-1": opusLegacyPricing,
        "claude-opus-4-20250514": opusLegacyPricing,
        "claude-sonnet-5": sonnetPricing,
        "claude-sonnet-4-6": sonnetPricing,
        "claude-sonnet-4-5": sonnetPricing,
        "claude-haiku-4-5": haiku45Pricing,
        "claude-haiku-3-5": haiku35Pricing,
    ]

    private static let fallbackPricing = sonnetPricing

    let projectsRootURL: URL

    /// Cache of parsed sessions keyed by file path, with the modification date used to invalidate.
    private var cache: [String: CachedSession] = [:]

    private struct CachedSession {
        let modificationDate: Date
        let sessionCost: SessionCost
    }

    init(
        projectsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    ) {
        self.projectsRootURL = projectsRootURL
    }

    func estimateCosts(now: Date = Date()) -> CostSnapshot {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        let sessionFiles = findSessionFiles(modifiedAfter: startOfWeek)
        var activeSessions: [SessionCost] = []
        var todayCost = 0.0
        var weekCost = 0.0
        var todaySessions = 0
        var weekSessions = 0

        var projectTodayCosts: [String: Double] = [:]
        var projectWeekCosts: [String: Double] = [:]
        var projectTodaySessionCounts: [String: Int] = [:]
        var projectWeekSessionCounts: [String: Int] = [:]

        // Track which cache keys are still valid this pass
        var activeCacheKeys: Set<String> = []

        for (projectPath, fileURL, modDate) in sessionFiles {
            let cacheKey = fileURL.path
            activeCacheKeys.insert(cacheKey)

            let sessionCost: SessionCost
            if let cached = cache[cacheKey], cached.modificationDate == modDate {
                sessionCost = cached.sessionCost
            } else if let parsed = Self.parseSession(fileURL: fileURL, projectPath: projectPath) {
                cache[cacheKey] = CachedSession(modificationDate: modDate, sessionCost: parsed)
                sessionCost = parsed
            } else {
                continue
            }

            let isToday = sessionCost.lastMessageAt.map { $0 >= startOfToday } ?? false
            let isThisWeek = sessionCost.lastMessageAt.map { $0 >= startOfWeek } ?? false

            if isToday {
                todayCost += sessionCost.totalCost
                todaySessions += 1
                activeSessions.append(sessionCost)
                projectTodayCosts[projectPath, default: 0] += sessionCost.totalCost
                projectTodaySessionCounts[projectPath, default: 0] += 1
                projectWeekCosts[projectPath, default: 0] += sessionCost.totalCost
                projectWeekSessionCounts[projectPath, default: 0] += 1
            } else if isThisWeek {
                weekCost += sessionCost.totalCost
                weekSessions += 1
                projectWeekCosts[projectPath, default: 0] += sessionCost.totalCost
                projectWeekSessionCounts[projectPath, default: 0] += 1
            }
        }

        // Evict deleted or now-stale files from cache
        let staleKeys = cache.keys.filter { !activeCacheKeys.contains($0) }
        for key in staleKeys {
            cache.removeValue(forKey: key)
        }

        activeSessions.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }

        let allProjectPaths = Set(projectTodayCosts.keys).union(projectWeekCosts.keys)
        let projectCosts = allProjectPaths.map { path in
            ProjectCost(
                projectName: path,
                todayCost: projectTodayCosts[path, default: 0],
                weekCost: projectWeekCosts[path, default: 0],
                todaySessions: projectTodaySessionCounts[path, default: 0],
                weekSessions: projectWeekSessionCounts[path, default: 0]
            )
        }.sorted { $0.todayCost > $1.todayCost }

        return CostSnapshot(
            activeSessions: activeSessions,
            todayCost: todayCost,
            weekCost: weekCost + todayCost,
            todaySessions: todaySessions,
            weekSessions: weekSessions + todaySessions,
            projectCosts: projectCosts
        )
    }

    // MARK: - Private

    private func findSessionFiles(modifiedAfter cutoff: Date) -> [(projectPath: String, fileURL: URL, modDate: Date)] {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(String, URL, Date)] = []
        for dir in projectDirs {
            guard let isDir = try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir else { continue }

            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let modDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    continue
                }
                guard modDate >= cutoff else { continue }
                results.append((dir.lastPathComponent, file, modDate))
            }
        }
        return results
    }

    /// Coerces JSON-decoded values (NSNumber, Double, String) to Int; returns nil if absent or non-numeric.
    private static func intFromJSON(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return Int(n.doubleValue.rounded()) }
        if let d = value as? Double { return Int(d.rounded()) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    private static func parseSession(fileURL: URL, projectPath: String) -> SessionCost? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var totalCost = 0.0
        var messageCount = 0
        var modelCounts: [String: Int] = [:]
        var firstTimestamp: Date?
        var lastTimestamp: Date?

        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            let msgModel = (message["model"] as? String) ?? ""
            if msgModel == "<synthetic>" { continue }

            // Match ccusage: only count rows with explicit input_tokens (allows 0).
            guard usage["input_tokens"] != nil, !(usage["input_tokens"] is NSNull) else { continue }
            guard let input = intFromJSON(usage["input_tokens"]) else { continue }

            messageCount += 1

            if !msgModel.isEmpty {
                modelCounts[msgModel, default: 0] += 1
            }

            let output = intFromJSON(usage["output_tokens"]) ?? 0
            let cacheCreation = intFromJSON(usage["cache_creation_input_tokens"]) ?? 0
            let cacheRead = intFromJSON(usage["cache_read_input_tokens"]) ?? 0

            totalInput += input
            totalOutput += output
            totalCacheCreation += cacheCreation
            totalCacheRead += cacheRead

            let msgUsage = TokenUsage(
                inputTokens: input, outputTokens: output,
                cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead
            )
            totalCost += pricingForModel(msgModel).cost(for: msgUsage)

            if let ts = obj["timestamp"] as? String, let date = parseISO8601(ts) {
                if firstTimestamp == nil { firstTimestamp = date }
                lastTimestamp = date
            }
        }

        guard messageCount > 0 else { return nil }

        let tokenUsage = TokenUsage(
            inputTokens: totalInput,
            outputTokens: totalOutput,
            cacheCreationTokens: totalCacheCreation,
            cacheReadTokens: totalCacheRead
        )

        let model = modelCounts.max(by: { $0.value < $1.value })?.key ?? ""

        return SessionCost(
            sessionID: sessionID,
            projectPath: projectPath,
            totalCost: totalCost,
            totalUsage: tokenUsage,
            model: model,
            messageCount: messageCount,
            firstMessageAt: firstTimestamp,
            lastMessageAt: lastTimestamp
        )
    }

    private static func pricingForModel(_ model: String) -> ModelPricing {
        if let exact = pricing[model] { return exact }
        for (key, value) in pricing where model.hasPrefix(key) {
            return value
        }

        let m = model.lowercased()

        if m.contains("fable") || m.contains("mythos") {
            return fablePricing
        }

        if m.contains("opus") {
            // Legacy $15/$75 tier is only Opus 3, Opus 4, and Opus 4.1. Everything
            // from Opus 4.5 onward (4.5/4.6/4.7/4.8 and any future release) is the
            // current $5/$25 tier, so default unknown Opus IDs to current pricing.
            let isLegacy = m.contains("opus-4-1") || m.contains("opus-4.1")
                || m.contains("opus-4-0") || m.contains("opus-4.0")
                || m.contains("opus-4-2025")            // dated Opus 4 snapshot
                || m.contains("opus-3") || m.contains("3-opus")
            return isLegacy ? opusLegacyPricing : opusCurrentPricing
        }

        if m.contains("haiku") {
            // Only Haiku 3 / 3.5 use the older tier; default newer Haiku to 4.5.
            if m.contains("haiku-3") || m.contains("3-5") || m.contains("3.5") {
                return haiku35Pricing
            }
            return haiku45Pricing
        }

        if m.contains("sonnet") { return sonnetPricing }

        return fallbackPricing
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let stripped: String
        if let dotIndex = string.firstIndex(of: "."),
           let zIndex = string.firstIndex(of: "Z"), dotIndex < zIndex {
            stripped = String(string[string.startIndex..<dotIndex]) + String(string[zIndex...])
        } else {
            stripped = string
        }
        return ISO8601DateFormatter().date(from: stripped)
    }
}
