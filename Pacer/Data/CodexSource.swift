import Foundation

/// Reads Codex limits from ChatGPT and the daily shape from Codex's session logs.
///
/// Current Codex builds no longer write rate limits into every session log, so the live numbers come from
/// the ChatGPT usage endpoint that powers `/status`. It authenticates with the sign-in Codex stores in
/// `~/.codex/auth.json`. Pacer only reads that file. If the endpoint fails, Pacer falls back to the logs.
struct CodexSource: Sendable {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    let scanner = CodexLogScanner(root: root)
    let readings = CodexReadings()

    func fetch(now: Date) async throws -> ProviderUsage {
        let observations = await scanner.observations(since: now.addingTimeInterval(-8 * 24 * 3600), now: now)
        if let live = try? await Self.fetchLimits(now: now), let weekly = live.weekly {
            // Log points and saved live readings from the same week give the daily shape.
            let saved = await readings.record(UsagePoint(date: now, usedPercent: weekly.usedPercent), resetsAt: weekly.resetsAt)
            let history = (Self.history(observations, matching: weekly) + saved).sorted { $0.date < $1.date }
            return ProviderUsage(
                weekly: UsageWindow(usedPercent: weekly.usedPercent, resetsAt: weekly.resetsAt, length: weekly.windowMinutes * 60),
                session: live.session.map { UsageWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, length: $0.windowMinutes * 60) },
                history: history,
                observedAt: now,
                historyIsEstimated: false
            )
        }

        guard let latest = observations.last(where: { $0.weekly != nil }), let weekly = latest.weekly else {
            throw SourceError.notFound("No Codex sessions in the last week. Pacer picks up your limits after your next Codex session.")
        }

        if weekly.resetsAt <= now {
            // The last known week is over. Codex starts the next one when you use it again.
            return ProviderUsage(
                weekly: UsageWindow(usedPercent: 0, resetsAt: now.addingTimeInterval(UsageWindow.week), length: UsageWindow.week),
                history: [],
                observedAt: latest.date,
                historyIsEstimated: false,
                note: "Your Codex week reset. The new one starts with your next session."
            )
        }

        let history = Self.history(observations, matching: weekly)
        let session = observations.last(where: { $0.session != nil })?.session.flatMap { limit in
            limit.resetsAt > now ? UsageWindow(usedPercent: limit.usedPercent, resetsAt: limit.resetsAt, length: limit.windowMinutes * 60) : nil
        }
        return ProviderUsage(
            weekly: UsageWindow(usedPercent: weekly.usedPercent, resetsAt: weekly.resetsAt, length: weekly.windowMinutes * 60),
            session: session,
            history: history,
            observedAt: latest.date,
            historyIsEstimated: false
        )
    }

    static func history(_ observations: [CodexLogScanner.Observation], matching weekly: CodexLogScanner.Limit) -> [UsagePoint] {
        observations.compactMap { observation in
            guard let limit = observation.weekly, abs(limit.resetsAt.timeIntervalSince(weekly.resetsAt)) < 3 * 3600 else { return nil }
            return UsagePoint(date: observation.date, usedPercent: limit.usedPercent)
        }
    }

    private static func fetchLimits(now: Date) async throws -> CodexLogScanner.Observation {
        let data = try Data(contentsOf: root.appending(path: "auth.json"))
        guard let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else {
            throw SourceError.notFound("Codex is not signed in with ChatGPT.")
        }
        var request = URLRequest(url: usageURL, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("Pacer", forHTTPHeaderField: "User-Agent")

        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let limits = root["rate_limit"] as? [String: Any] else {
            throw SourceError.unexpected("ChatGPT's usage service returned HTTP \(status).")
        }
        var observation = CodexLogScanner.Observation(date: now)
        for key in ["primary_window", "secondary_window"] {
            guard let object = limits[key] as? [String: Any],
                  let used = JSONLines.number(object["used_percent"]),
                  let seconds = JSONLines.number(object["limit_window_seconds"]),
                  let reset = JSONLines.number(object["reset_at"]) else { continue }
            CodexLogScanner.classify(
                CodexLogScanner.Limit(usedPercent: used, windowMinutes: seconds / 60, resetsAt: Date(timeIntervalSince1970: reset)),
                into: &observation
            )
        }
        return observation
    }
}

/// Saves live weekly readings, because current Codex builds no longer record them in session logs.
actor CodexReadings {
    private struct Week: Codable {
        var resetsAt: Date
        var points: [UsagePoint]
    }

    private static let key = "codexReadings"
    private var week: Week? = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Week.self, from: $0) }

    /// Adds a reading when the percentage changed and returns the week's readings, oldest first.
    func record(_ point: UsagePoint, resetsAt: Date) -> [UsagePoint] {
        var current = week.flatMap { abs($0.resetsAt.timeIntervalSince(resetsAt)) < 3 * 3600 ? $0 : nil }
            ?? Week(resetsAt: resetsAt, points: [])
        if current.points.last?.usedPercent != point.usedPercent {
            current.points.append(point)
            if let data = try? JSONEncoder().encode(current) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
        week = current
        return current.points
    }
}

actor CodexLogScanner {
    struct Limit: Equatable, Sendable {
        var usedPercent: Double
        var windowMinutes: Double
        var resetsAt: Date
    }

    struct Observation: Sendable {
        var date: Date
        var weekly: Limit?
        var session: Limit?
    }

    private struct FileState {
        var offset: UInt64 = 0
        var observations: [Observation] = []
    }

    private let root: URL
    private var files: [String: FileState] = [:]

    init(root: URL) {
        self.root = root
    }

    func observations(since start: Date, now: Date) -> [Observation] {
        for url in candidateFiles(since: start, now: now) {
            update(url)
        }
        return files.values
            .flatMap(\.observations)
            .filter { $0.date >= start }
            .sorted { $0.date < $1.date }
    }

    /// Session logs live in `sessions/YYYY/MM/DD`, so only the folders for the window are listed.
    private func candidateFiles(since start: Date, now: Date) -> [URL] {
        let calendar = Calendar.current
        var urls: [URL] = []
        var day = calendar.startOfDay(for: start.addingTimeInterval(-24 * 3600))
        while day <= now {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appending(path: String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            urls += JSONLines.files(under: folder, modifiedSince: start)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        urls += JSONLines.files(under: root.appending(path: "archived_sessions"), modifiedSince: start)
        return urls
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

        var observations = state.observations
        let offset = (try? JSONLines.scan(url, from: state.offset, needle: "\"rate_limits\"") { line in
            guard let timestamp = line["timestamp"] as? String,
                  let date = Dates.parseISO(timestamp),
                  let payload = line["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { return }
            if let id = limits["limit_id"] as? String, id != "codex" { return }

            var observation = Observation(date: date)
            for key in ["primary", "secondary"] {
                guard let limit = Self.limit(limits[key], observedAt: date) else { continue }
                Self.classify(limit, into: &observation)
            }
            guard observation.weekly != nil || observation.session != nil else { return }
            // Codex repeats the same numbers on every turn. Keep only changes.
            if let last = observations.last, last.weekly == observation.weekly, last.session == observation.session { return }
            observations.append(observation)
        }) ?? state.offset
        state.offset = offset
        state.observations = observations
        files[path] = state
    }

    static func classify(_ limit: Limit, into observation: inout Observation) {
        if limit.windowMinutes >= 7 * 24 * 60 * 0.9 {
            observation.weekly = limit
        } else if limit.windowMinutes < 24 * 60 {
            observation.session = limit
        }
    }

    private static func limit(_ value: Any?, observedAt date: Date) -> Limit? {
        guard let object = value as? [String: Any],
              let used = JSONLines.number(object["used_percent"]),
              let minutes = JSONLines.number(object["window_minutes"]) else { return nil }
        let resetsAt: Date
        if let epoch = JSONLines.number(object["resets_at"]) {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let seconds = JSONLines.number(object["resets_in_seconds"]) {
            resetsAt = date.addingTimeInterval(seconds)
        } else {
            return nil
        }
        return Limit(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt)
    }
}
