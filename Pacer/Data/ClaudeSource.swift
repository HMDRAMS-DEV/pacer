import Foundation

/// Reads Claude's limits from Anthropic and the daily shape from local Claude Code logs.
///
/// Claude Code does not write limit percentages to disk, so the weekly and 5-hour numbers come from
/// the OAuth usage endpoint that powers `/usage`. It authenticates with the sign-in Claude Code already
/// stores in the Keychain. Pacer only reads that item. It never refreshes or rewrites it.
struct ClaudeSource: Sendable {
    static let keychainService = "Claude Code-credentials"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let scanner = ClaudeLogScanner(
        root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    )

    func fetch(now: Date) async throws -> ProviderUsage {
        let token = try await Task.detached { try Self.readToken(now: now) }.value
        let (weekly, session) = try await Self.fetchLimits(token: token, now: now)
        let events = await scanner.events(since: weekly.start)
        return ProviderUsage(
            weekly: weekly,
            session: session,
            history: Self.history(events: events, weekly: weekly, now: now),
            observedAt: now,
            historyIsEstimated: true
        )
    }

    /// Spreads the exact weekly percentage over time in proportion to local token use.
    static func history(events: [WeightedEvent], weekly: UsageWindow, now: Date) -> [UsagePoint] {
        let total = events.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return [UsagePoint(date: now, usedPercent: weekly.usedPercent)] }
        // One point per hour is plenty for daily bars and keeps lookups cheap.
        var running = 0.0
        var points: [UsagePoint] = []
        for event in events {
            running += event.weight
            let point = UsagePoint(date: event.date, usedPercent: weekly.usedPercent * running / total)
            if let last = points.last, Int(last.date.timeIntervalSince1970 / 3600) == Int(event.date.timeIntervalSince1970 / 3600) {
                points[points.count - 1] = point
            } else {
                points.append(point)
            }
        }
        return points
    }

    private static func readToken(now: Date) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw SourceError.notFound("Pacer couldn't find a Claude Code sign-in. Run `claude` in Terminal, sign in, then try again.")
        }
        if let expiresAt = JSONLines.number(oauth["expiresAt"]), Date(timeIntervalSince1970: expiresAt / 1000) < now {
            throw SourceError.signedOut
        }
        return token
    }

    private static func fetchLimits(token: String, now: Date) async throws -> (UsageWindow, UsageWindow?) {
        var request = URLRequest(url: usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Pacer", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw SourceError.signedOut }
        guard status == 200, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.unexpected("Anthropic's usage service returned HTTP \(status). Pacer will try again shortly.")
        }
        guard let weekly = window(root["seven_day"], length: UsageWindow.week, now: now) else {
            throw SourceError.unexpected("Your Claude plan doesn't report a weekly limit.")
        }
        return (weekly, window(root["five_hour"], length: 5 * 3600, now: now))
    }

    private static func window(_ value: Any?, length: TimeInterval, now: Date) -> UsageWindow? {
        guard let object = value as? [String: Any], let used = JSONLines.number(object["utilization"]) else { return nil }
        // An unused window has no reset yet. Treat it as starting now.
        let resetsAt = (object["resets_at"] as? String).flatMap(Dates.parseISO) ?? now.addingTimeInterval(length)
        return UsageWindow(usedPercent: used, resetsAt: resetsAt, length: length)
    }
}

struct WeightedEvent: Sendable {
    let date: Date
    let weight: Double
}

/// Keeps a running, per-message summary of token use from Claude Code's session logs.
actor ClaudeLogScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var messages: [String: WeightedEvent] = [:]
    }

    private let root: URL
    private var files: [String: FileState] = [:]

    init(root: URL) {
        self.root = root
    }

    func events(since start: Date) -> [WeightedEvent] {
        for url in JSONLines.files(under: root, modifiedSince: start) {
            update(url)
        }
        // Resumed sessions copy earlier messages into new files, so merge by message ID.
        var merged: [String: WeightedEvent] = [:]
        for (path, state) in files {
            let recent = state.messages.filter { $0.value.date >= start }
            if recent.isEmpty, state.messages.count > 0 {
                files[path]?.messages = [:]
            }
            for (id, event) in recent where event.weight > (merged[id]?.weight ?? -1) {
                merged[id] = event
            }
        }
        return merged.values.sorted { $0.date < $1.date }
    }

    private func update(_ url: URL) {
        let path = url.path
        var state = files[path] ?? FileState()
        let size = JSONLines.size(of: url)
        if size < state.offset { state = FileState() }
        guard size > state.offset else {
            files[path] = state
            return
        }

        var messages = state.messages
        let offset = (try? JSONLines.scan(url, from: state.offset, needle: "\"usage\"") { line in
            guard line["type"] as? String == "assistant",
                  let message = line["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = line["timestamp"] as? String,
                  let date = Dates.parseISO(timestamp) else { return }
            let id = (message["id"] as? String) ?? (line["requestId"] as? String) ?? (line["uuid"] as? String) ?? UUID().uuidString
            let weight = Self.weight(usage: usage, model: message["model"] as? String)
            // Streaming writes the same message several times. Keep the most complete copy.
            if weight > (messages[id]?.weight ?? -1) {
                messages[id] = WeightedEvent(date: date, weight: weight)
            }
        }) ?? state.offset
        state.offset = offset
        state.messages = messages
        files[path] = state
    }

    /// Approximate cost of a message, relative to Opus input tokens.
    ///
    /// Limits are metered on compute, not raw tokens, so this uses list-price ratios between token types and models.
    static func weight(usage: [String: Any], model: String?) -> Double {
        func tokens(_ key: String) -> Double { JSONLines.number(usage[key]) ?? 0 }
        let raw = tokens("input_tokens")
            + 1.25 * tokens("cache_creation_input_tokens")
            + 0.1 * tokens("cache_read_input_tokens")
            + 5 * tokens("output_tokens")
        let model = model?.lowercased() ?? ""
        let factor = model.contains("haiku") ? 0.2 : model.contains("sonnet") ? 0.6 : 1
        return raw * factor
    }
}
