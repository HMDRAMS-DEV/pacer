import AppKit
import Foundation
import Observation

enum Keys {
    static let setupDone = "setupDone"
    static let plan = "plan"
    /// Plans used to be per tool. Read once to carry an existing plan over.
    static let legacyPlans = "plans"
    static let enabled = "enabledProviders"
    static let alertsEnabled = "alertsEnabled"
    static let chartStyle = "chartStyle"
}

/// How a card draws the week.
enum ChartStyle: String, CaseIterable, Identifiable {
    case line, dots

    var id: String { rawValue }

    var label: String {
        switch self {
        case .line: "Line"
        case .dots: "Dots"
        }
    }
}

enum WindowID {
    static let main = "main"
    static let setup = "setup"
    static let settings = "settings"
}

/// One bar in a week chart.
struct DayBar: Identifiable {
    var id: Date { date }
    let date: Date
    let letter: String
    let planned: Double
    let actual: Double
    let isToday: Bool
    let isPast: Bool
    let isSpendingDay: Bool
}

@MainActor
@Observable
final class PacerStore {
    private(set) var usage: [Provider: ProviderUsage] = [:]
    private(set) var errors: [Provider: String] = [:]
    private(set) var lastRefresh: Date?
    private(set) var now = Date()
    private(set) var isRefreshing = false
    /// The tool the main window shows.
    var focus: Provider = .claude

    /// One plan for every tool: people finish, spread, and work the same week whichever tool they use.
    var plan: PacePlan {
        didSet { Self.save(plan, key: Keys.plan) }
    }

    var enabled: Set<Provider> {
        didSet { Self.save(enabled, key: Keys.enabled) }
    }

    @ObservationIgnored private let claude = ClaudeSource()
    @ObservationIgnored private let codex = CodexSource()
    @ObservationIgnored private var lastClaudeAttempt: Date?
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Claude limits come from the network, so they refresh less often than local Codex logs.
    private static let claudeInterval: TimeInterval = 5 * 60

    init() {
        UserDefaults.standard.register(defaults: [Keys.alertsEnabled: true])
        let legacy: [Provider: PacePlan]? = Self.load(key: Keys.legacyPlans)
        plan = Self.load(key: Keys.plan) ?? legacy?[.claude] ?? PacePlan()
        enabled = Self.load(key: Keys.enabled) ?? Set(Provider.allCases)
    }

    #if DEBUG
    /// A store with fixed data, for previews and snapshot tests.
    init(preview usage: [Provider: ProviderUsage], now: Date) {
        plan = PacePlan()
        enabled = Set(Provider.allCases)
        self.usage = usage
        self.now = now
        lastRefresh = now.addingTimeInterval(-120)
    }
    #endif

    /// Starts the refresh loop. Safe to call more than once.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        now = Date()
        for provider in Provider.allCases where enabled.contains(provider) {
            if provider == .claude, !force, let last = lastClaudeAttempt, now.timeIntervalSince(last) < Self.claudeInterval {
                continue
            }
            await load(provider)
        }
        now = Date()
        lastRefresh = now
        if UserDefaults.standard.bool(forKey: Keys.alertsEnabled) {
            PaceAlerts.evaluate(reports, plan: plan, now: now)
        }
    }

    /// Fetches one provider and returns the error message on failure.
    @discardableResult
    func load(_ provider: Provider) async -> String? {
        do {
            let result: ProviderUsage
            switch provider {
            case .claude:
                lastClaudeAttempt = Date()
                result = try await claude.fetch(now: Date())
            case .codex:
                result = try await codex.fetch(now: Date())
            }
            usage[provider] = result
            errors[provider] = nil
            now = Date()
            return nil
        } catch {
            let message = error.localizedDescription
            errors[provider] = message
            return message
        }
    }

    // MARK: - Derived state

    var activeProviders: [Provider] {
        Provider.allCases.filter { enabled.contains($0) }
    }

    func report(for provider: Provider) -> PaceReport? {
        guard let usage = usage[provider] else { return nil }
        return PaceReport(provider: provider, window: usage.weekly, plan: plan, now: now)
    }

    var reports: [PaceReport] {
        activeProviders.compactMap(report(for:))
    }

    var iconRings: [MenuBarIcon.Ring] {
        activeProviders.map { provider in
            guard let report = report(for: provider) else { return MenuBarIcon.Ring(used: 0, expected: nil, alert: false) }
            let alert = report.state == .out || (report.state == .hot && report.runOutAt.map { $0 < report.finishBy } == true)
            return MenuBarIcon.Ring(used: report.used / 100, expected: report.expected / 100, alert: alert)
        }
    }

    /// One line describing every tracked tool.
    var summary: String {
        let parts = activeProviders.compactMap { provider -> String? in
            guard let report = report(for: provider) else { return nil }
            return "\(provider.name) \(report.state.phrase)"
        }
        return parts.isEmpty ? "Waiting for your first numbers." : parts.joined(separator: ". ") + "."
    }

    func bars(for provider: Provider) -> [DayBar] {
        guard let usage = usage[provider], let report = report(for: provider) else { return [] }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let letters = calendar.veryShortWeekdaySymbols
        return report.schedule.days.map { day in
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day.date) ?? day.date
            let from = max(day.date, usage.weekly.start)
            return DayBar(
                date: day.date,
                letter: letters[calendar.component(.weekday, from: day.date) - 1],
                planned: report.target * day.share,
                actual: day.date <= today ? usage.spent(from: from, to: min(dayEnd, now)) : 0,
                isToday: day.date == today,
                isPast: day.date < today,
                isSpendingDay: day.share > 0
            )
        }
    }

    // MARK: - Persistence

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

extension PaceState {
    var phrase: String {
        switch self {
        case .fresh: "is starting a fresh week"
        case .onPace: "is on pace"
        case .hot: "is running hot"
        case .slack: "has room to spare"
        case .out: "is out until it resets"
        case .done: "hit this week's target"
        }
    }

    /// One or two words for the mood chip.
    var chip: String {
        switch self {
        case .fresh: "Fresh"
        case .onPace: "On pace"
        case .hot: "Ease off"
        case .slack: "Lean in"
        case .out: "Out"
        case .done: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .fresh: "sparkles"
        case .onPace: "checkmark"
        case .hot: "flame.fill"
        case .slack: "arrow.up.right"
        case .out: "moon.zzz.fill"
        case .done: "checkmark.seal.fill"
        }
    }

    var headline: String {
        switch self {
        case .fresh: "Fresh week"
        case .onPace: "On pace"
        case .hot: "Running hot"
        case .slack: "Room to lean in"
        case .out: "Limit reached"
        case .done: "Target reached"
        }
    }
}

enum Tone {
    case good, bad, neutral, accent
}

extension PaceReport {
    /// The one line that matters most right now, like a flight's "Landing in 3h 49m".
    func band(now: Date) -> (symbol: String, text: String, tone: Tone) {
        let reset = Format.countdown(to: resetsAt, now: now)
        switch state {
        case .hot:
            if let runOutAt, runOutAt < finishBy {
                return ("flame.fill", "Runs out in \(Format.countdown(to: runOutAt, now: now))", .bad)
            }
            return ("flame.fill", "Ease off today", .bad)
        case .out:
            return ("moon.zzz.fill", "Back in \(reset)", .bad)
        case .slack:
            if now >= finishBy {
                return ("gift.fill", "\(Format.percent(100 - used)) spare, resets in \(reset)", .good)
            }
            return ("arrow.up.right", "Room for \(Format.percent(typicalDay)) a day", .good)
        case .onPace:
            return todayLeft >= 0.5
                ? ("sun.max.fill", "\(Format.percent(todayLeft)) left today", .accent)
                : ("checkmark", "On pace, resets in \(reset)", .neutral)
        case .fresh:
            let spendingDays = schedule.days.filter { $0.share > 0 }
            if shape != .even, let first = spendingDays.first, spendingDays.count > 1 {
                let day = first.start.formatted(.dateTime.weekday(.abbreviated))
                let direction = shape == .frontLoaded ? "taper" : "build"
                return ("sparkles", "Aim for \(Format.percent(target * first.share)) \(day), then \(direction)", .accent)
            }
            return ("sparkles", "Fresh week, \(Format.percent(typicalDay)) a day", .accent)
        case .done:
            return ("checkmark.seal.fill", "Target hit, resets in \(reset)", .good)
        }
    }

    /// Actual versus plan, like "18% over" or "12% under".
    var delta: (text: String, tone: Tone) {
        let difference = used - expected
        if abs(difference) < 1 { return ("on plan", .neutral) }
        return difference > 0
            ? ("\(Format.percent(difference)) over", .bad)
            : ("\(Format.percent(-difference)) under", .good)
    }

    func detail(now: Date) -> String {
        let finish = Format.weekday(finishBy)
        switch state {
        case .fresh:
            let spendingDays = schedule.days.filter { $0.share > 0 }
            if shape != .even, let first = spendingDays.first, let last = spendingDays.last, first.date != last.date {
                let firstTarget = Format.percent(target * first.share)
                let lastTarget = Format.percent(target * last.share)
                let change = shape == .frontLoaded ? "tapers" : "builds"
                return "Plan starts at \(firstTarget) \(Format.weekday(first.start)) and \(change) to \(lastTarget) \(Format.weekday(last.start))."
            }
            return "Plan on about \(Format.percent(typicalDay)) a day through \(finish)."
        case .onPace:
            return todayLeft >= 0.5
                ? "About \(Format.percent(todayLeft)) left for today."
                : "Today's share is spent. Next up: about \(Format.percent(perDayAfterToday)) a day."
        case .hot:
            let advice = todayLeft >= 0.5
                ? "Keep today under \(Format.percent(todayLeft))."
                : "Aim for under \(Format.percent(perDayAfterToday)) a day from here."
            if let runOutAt, runOutAt < finishBy {
                return "At this pace you'll run out \(Format.moment(runOutAt, now: now)). \(advice)"
            }
            return "You're \(Format.percent(used - expected)) ahead of plan. \(advice)"
        case .slack:
            if now >= finishBy {
                return "\(Format.percent(100 - used)) left until it resets \(Format.moment(resetsAt, now: now))."
            }
            let leftover = max(0, target - (projectedAtFinish ?? used))
            return "On track to leave \(Format.percent(leftover)) unused. You can spend about \(Format.percent(typicalDay)) a day through \(finish)."
        case .out:
            return "Resets \(Format.moment(resetsAt, now: now))."
        case .done:
            return "Anything extra before \(Format.moment(resetsAt, now: now)) is a bonus."
        }
    }
}
