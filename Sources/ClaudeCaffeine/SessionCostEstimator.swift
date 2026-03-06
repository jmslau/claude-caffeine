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

struct CostSnapshot: Sendable {
    let activeSessions: [SessionCost]
    let todayCost: Double
    let weekCost: Double
    let todaySessions: Int
    let weekSessions: Int
}

struct SessionCostEstimator: Sendable {
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

        let sessionFiles = findSessionFiles()
        var activeSessions: [SessionCost] = []
        var todayCost = 0.0
        var weekCost = 0.0
        var todaySessions = 0
        var weekSessions = 0

        for (projectPath, fileURL) in sessionFiles {
            guard let sessionCost = parseSession(fileURL: fileURL, projectPath: projectPath) else {
                continue
            }

            let isToday = sessionCost.lastMessageAt.map { $0 >= startOfToday } ?? false
            let isThisWeek = sessionCost.lastMessageAt.map { $0 >= startOfWeek } ?? false

            if isToday {
                todayCost += sessionCost.totalCost
                todaySessions += 1
                activeSessions.append(sessionCost)
            } else if isThisWeek {
                weekCost += sessionCost.totalCost
                weekSessions += 1
            }
        }

        activeSessions.sort { ($0.lastMessageAt ?? .distantPast) > ($1.lastMessageAt ?? .distantPast) }

        return CostSnapshot(
            activeSessions: activeSessions,
            todayCost: todayCost,
            weekCost: weekCost + todayCost,
            todaySessions: todaySessions,
            weekSessions: weekSessions + todaySessions
        )
    }

    // MARK: - Private

    private func findSessionFiles() -> [(projectPath: String, fileURL: URL)] {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(String, URL)] = []
        for dir in projectDirs {
            guard let isDir = try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir else { continue }

            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                results.append((dir.lastPathComponent, file))
            }
        }
        return results
    }

    private func parseSession(fileURL: URL, projectPath: String) -> SessionCost? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let sessionID = fileURL.deletingPathExtension().lastPathComponent
        var totalInput = 0
        var totalOutput = 0
        var totalCacheCreation = 0
        var totalCacheRead = 0
        var messageCount = 0
        var model = ""
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

            if let m = message["model"] as? String, !m.isEmpty {
                model = m
            }

            totalInput += usage["input_tokens"] as? Int ?? 0
            totalOutput += usage["output_tokens"] as? Int ?? 0
            totalCacheCreation += usage["cache_creation_input_tokens"] as? Int ?? 0
            totalCacheRead += usage["cache_read_input_tokens"] as? Int ?? 0

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

        let pricing = Self.pricingForModel(model)
        let cost = pricing.cost(for: tokenUsage)

        return SessionCost(
            sessionID: sessionID,
            projectPath: projectPath,
            totalCost: cost,
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

    private func parseISO8601(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
