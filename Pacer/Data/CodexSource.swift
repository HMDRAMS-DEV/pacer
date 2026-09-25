import Foundation

/// Reads Codex limits from the rate-limit events Codex writes into its session logs.
///
/// Everything is local. The numbers are as fresh as the last Codex session on this Mac.
struct CodexSource: Sendable {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")

    let scanner = CodexLogScanner(root: root)

    func fetch(now: Date) async throws -> ProviderUsage {
        let observations = await scanner.observations(since: now.addingTimeInterval(-8 * 24 * 3600), now: now)
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

        let history = observations.compactMap { observation -> UsagePoint? in
            guard let limit = observation.weekly, abs(limit.resetsAt.timeIntervalSince(weekly.resetsAt)) < 3 * 3600 else { return nil }
            return UsagePoint(date: observation.date, usedPercent: limit.usedPercent)
        }
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
                if limit.windowMinutes >= 7 * 24 * 60 * 0.9 {
                    observation.weekly = limit
                } else if limit.windowMinutes < 24 * 60 {
                    observation.session = limit
                }
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
