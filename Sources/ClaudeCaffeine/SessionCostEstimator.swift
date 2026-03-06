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
    private static let pricing: [String: ModelPricing] = [
        "claude-opus-4-6": ModelPricing(
            inputPerMillion: 15.0, outputPerMillion: 75.0,
            cacheCreationPerMillion: 18.75, cacheReadPerMillion: 1.50
        ),
        "claude-sonnet-4-6": ModelPricing(
            inputPerMillion: 3.0, outputPerMillion: 15.0,
            cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30
        ),
        "claude-haiku-4-5": ModelPricing(
            inputPerMillion: 0.80, outputPerMillion: 4.0,
            cacheCreationPerMillion: 1.0, cacheReadPerMillion: 0.08
        ),
    ]

    private static let fallbackPricing = ModelPricing(
        inputPerMillion: 3.0, outputPerMillion: 15.0,
        cacheCreationPerMillion: 3.75, cacheReadPerMillion: 0.30
    )

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

            messageCount += 1

            let msgModel = (message["model"] as? String) ?? ""
            if !msgModel.isEmpty {
                modelCounts[msgModel, default: 0] += 1
            }

            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

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
        if model.contains("opus") { return pricing["claude-opus-4-6"]! }
        if model.contains("haiku") { return pricing["claude-haiku-4-5"]! }
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
