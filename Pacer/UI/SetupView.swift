import ServiceManagement
import SwiftUI

/// First-run flow. Every permission is explained before Pacer asks for it, and every step can be skipped.
///
/// Each step leads with a picture of what it does and keeps the words short.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case welcome, claude, codex, alerts, plan
    }

    enum CheckStatus: Equatable {
        case idle, checking, ok(String), failed(String)
    }

    @Environment(PacerStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Keys.setupDone) private var setupDone = false
    @AppStorage(Keys.alertsEnabled) private var alertsEnabled = true

    @State private var step = Step.welcome
    @State private var claude = CheckStatus.idle
    @State private var codex = CheckStatus.idle
    @State private var notifications = CheckStatus.idle
    @State private var plan = PacePlan()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Starts on `step`. Setup always starts at the beginning; snapshots render the other steps.
    init(step: Step = .welcome) {
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .claude: connect(.claude, status: claude)
                case .codex: connect(.codex, status: codex)
                case .alerts: alertsStep
                case .plan: planStep
                }
            }
            .id(step)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity.combined(with: .offset(x: -24))
            ))
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 32)
            buttons
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 24)
        // One height for every step, sized to the tallest (the plan), so the buttons never move.
        .frame(width: 560, height: 576)
        .background(Theme.canvas)
        .animation(.spring(response: 0.4, dampingFraction: 0.9), value: step)
        .onAppear {
            // Menu bar apps don't come forward on their own, so bring the welcome window to the front.
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(WindowID.setup) == true }?.orderFrontRegardless()
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Hero(tint: Theme.accent) {
                FloatingIcon()
            }
            heading("Pace your week.", "Know when to push and when to ease off.")
        }
    }

    private func connect(_ provider: Provider, status: CheckStatus) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Hero(tint: Theme.tint(provider)) {
                ConnectPicture(provider: provider, status: status)
            }
            switch provider {
            case .claude:
                heading("Connect Claude", "Read-only. Your prompts never leave.")
            case .codex:
                heading("Connect Codex", "Local logs only. Nothing leaves your Mac.")
            }
            statusLine(status, hint: provider == .claude ? "If macOS asks for access, choose Always Allow." : nil)
        }
    }

    private var alertsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Hero(tint: Theme.slack) {
                VStack(spacing: -14) {
                    NotificationMock(title: "Ease off Claude", text: "Runs out Thu 2pm at this pace.")
                        .zIndex(1)
                    NotificationMock(title: "Lean into Codex", text: "26% to spare this week.")
                        .scaleEffect(0.92)
                        .opacity(0.7)
                        .offset(y: 10)
                }
                .padding(.horizontal, 72)
            }
            heading("Get a heads-up", "Only when your week drifts.")
            statusLine(notifications, hint: nil)
        }
    }

    private var planStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Hero(tint: Theme.accent) {
                PlanPreview(plan: plan)
            }
            heading("Set your finish line", nil)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    label("Finish by")
                    FinishPicker(weekday: $plan.finishWeekday)
                }
                GridRow {
                    label("Spread")
                    Picker("Spread", selection: $plan.shape) {
                        ForEach(PlanShape.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label("Days")
                    WeekdayChips(selection: $plan.activeWeekdays)
                }
                GridRow {
                    label("Hours")
                    HStack(spacing: 6) {
                        Picker("From", selection: $plan.dayStartHour) {
                            ForEach(0..<24, id: \.self) { Text(Format.hour($0)).tag($0) }
                        }
                        Text("to").foregroundStyle(Theme.muted)
                        Picker("To", selection: $plan.dayEndHour) {
                            ForEach((plan.dayStartHour + 1)...24, id: \.self) { Text(Format.hour($0)).tag($0) }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    label("At login")
                    Toggle("Open Pacer at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
            .font(.system(size: 13))
            .onChange(of: plan.dayStartHour) { _, start in
                if plan.dayEndHour <= start { plan.dayEndHour = start + 1 }
            }
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            progress
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.trailing, 4)
            }
            if let skip = skipTitle {
                Button(skip) { skipStep() }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
            Button(primaryTitle) { Task { await primary() } }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(isChecking)
        }
    }

    /// Where you are, drawn as dots like everything else.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Theme.accent : Theme.quietWash)
                    .frame(width: item == step ? 20 : 7, height: 7)
            }
        }
    }

    private var isChecking: Bool {
        [claude, codex, notifications].contains(.checking)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get started"
        case .claude: if case .ok = claude { "Continue" } else { "Connect" }
        case .codex: if case .ok = codex { "Continue" } else { "Connect" }
        case .alerts: if case .ok = notifications { "Continue" } else { "Allow" }
        case .plan: "Start pacing"
        }
    }

    private var skipTitle: String? {
        switch step {
        case .claude: if case .ok = claude { nil } else { "I don't use Claude" }
        case .codex: if case .ok = codex { nil } else { "I don't use Codex" }
        case .alerts: if case .ok = notifications { nil } else { "Not now" }
        default: nil
        }
    }

    private func primary() async {
        switch step {
        case .welcome:
            move(1)
        case .claude:
            if case .ok = claude { return move(1) }
            claude = await connect(.claude)
        case .codex:
            if case .ok = codex { return move(1) }
            codex = await connect(.codex)
        case .alerts:
            if case .ok = notifications { return move(1) }
            notifications = .checking
            if await PaceAlerts.requestPermission() {
                alertsEnabled = true
                notifications = .ok("Notifications on")
            } else {
                notifications = .failed("Off. Turn on in System Settings > Notifications.")
            }
        case .plan:
            finish()
        }
    }

    private func skipStep() {
        switch step {
        case .claude: store.enabled.remove(.claude)
        case .codex: store.enabled.remove(.codex)
        case .alerts: alertsEnabled = false
        default: break
        }
        move(1)
    }

    private func connect(_ provider: Provider) async -> CheckStatus {
        store.enabled.insert(provider)
        if provider == .claude { claude = .checking } else { codex = .checking }
        if let error = await store.load(provider) {
            return .failed(error)
        }
        let used = store.usage[provider].map { Format.percent($0.weekly.usedPercent) } ?? "?"
        return .ok("Connected · \(used) used")
    }

    private func move(_ delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) { step = next }
    }

    private func finish() {
        store.plan = plan
        if launchAtLogin, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        setupDone = true
        Task { await store.refresh(force: true) }
        dismissWindow(id: WindowID.setup)
    }

    // MARK: - Pieces

    private func heading(_ title: String, _ subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .display(28)
                .foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Theme.muted)
            .gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private func statusLine(_ status: CheckStatus, hint: String?) -> some View {
        switch status {
        case .idle:
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        case .ok(let message):
            chip(message, symbol: "checkmark.circle.fill", tone: .good)
        case .failed(let message):
            chip(message, symbol: "exclamationmark.circle.fill", tone: .bad)
        }
    }

    private func chip(_ text: String, symbol: String, tone: Tone) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(tone.wash, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Pictures

/// The app icon, large and drifting gently.
private struct FloatingIcon: View {
    @State private var up = false

    var body: some View {
        Image(nsImage: Theme.appIcon)
            .resizable()
            .frame(width: 150, height: 150)
            .shadow(color: Theme.accent.opacity(0.35), radius: 24, y: up ? 14 : 8)
            .offset(y: up ? -5 : 5)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

/// A tinted stage for each step's picture, textured with a faint dot grid.
private struct Hero<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                let step: CGFloat = 12
                var y = step / 2
                while y < size.height {
                    var x = step / 2
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(.primary.opacity(0.08)))
                        x += step
                    }
                    y += step
                }
            }
            content
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The app icon's idea at any size: columns of dots climbing, a bright dot for now, rings for the plan.
struct DotStairs: View {
    struct Column: Equatable {
        var filled: Int
        var ring: Int?
        var dimmed = false
    }

    struct Position: Equatable {
        let column: Int
        let row: Int
    }

    let columns: [Column]
    let rows: Int
    var dot: CGFloat = 12
    var spacing: CGFloat = 6
    /// Space between columns. Defaults to `spacing`.
    var columnSpacing: CGFloat?
    var tint = Theme.accent
    var now: Position?
    var labels: [String]?

    @State private var shown = false

    var body: some View {
        HStack(alignment: .bottom, spacing: columnSpacing ?? spacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                VStack(spacing: spacing) {
                    ForEach((0..<rows).reversed(), id: \.self) { row in
                        mark(column: index, row: row, in: column)
                            .frame(width: dot, height: dot)
                            .scaleEffect(shown ? 1 : 0.2)
                            .opacity(shown ? 1 : 0)
                            .animation(.spring(response: 0.45, dampingFraction: 0.75).delay(Double(index) * 0.035 + Double(row) * 0.02), value: shown)
                    }
                    if let labels {
                        Text(labels[index])
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .frame(height: 12)
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: columns)
        .onAppear { shown = true }
    }

    @ViewBuilder
    private func mark(column: Int, row: Int, in data: Column) -> some View {
        if now == Position(column: column, row: row) {
            Circle()
                .fill(.white)
                .shadow(color: tint.opacity(0.9), radius: dot * 0.35)
                .overlay(Circle().strokeBorder(tint.opacity(0.3), lineWidth: 1))
        } else if row < data.filled {
            Circle()
                .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .topTrailing, endPoint: .bottomLeading))
                .opacity(data.dimmed ? 0.35 : 1)
        } else if data.ring == row {
            Circle()
                .strokeBorder(Theme.ink.opacity(0.7), lineWidth: max(1.5, dot * 0.16))
        } else {
            Circle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: dot * 0.3, height: dot * 0.3)
        }
    }
}

/// The tool's mark, a dotted line, and Pacer's mark. The line turns green once connected.
private struct ConnectPicture: View {
    let provider: Provider
    let status: SetupView.CheckStatus

    @State private var phase = 0.0

    private var connected: Bool {
        if case .ok = status { true } else { false }
    }

    var body: some View {
        HStack(spacing: 18) {
            tile {
                provider.logo
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Theme.ink)
            }
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    Circle()
                        .fill(connected ? Theme.slack : Theme.tint(provider))
                        .frame(width: 7, height: 7)
                        .opacity(connected ? 1 : 0.25 + 0.75 * wave(index))
                }
            }
            tile {
                DotStairs(
                    columns: [1, 2, 3, 0].map { DotStairs.Column(filled: $0) }.enumerated().map { index, column in
                        var column = column
                        if index == 3 { column.ring = 3 }
                        return column
                    },
                    rows: 4,
                    dot: 9,
                    spacing: 4,
                    now: DotStairs.Position(column: 2, row: 2)
                )
            }
        }
        .overlay(alignment: .top) {
            if connected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Theme.slack)
                    .offset(y: -30)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: connected)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }

    /// A pulse that travels along the dotted line while waiting.
    private func wave(_ index: Int) -> Double {
        let position = phase * 6 - Double(index)
        return max(0, 1 - abs(position - 0.5))
    }

    private func tile<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 84, height: 84)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

/// A banner in the shape of a macOS notification.
private struct NotificationMock: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: Theme.appIcon)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(text).font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.75)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

/// A week of dots that follows the plan as you change it: how much of the target is spent by the
/// end of each day. The finish day is marked, and days after it are dimmed.
private struct PlanPreview: View {
    let plan: PacePlan

    private let rows = 8

    var body: some View {
        let week = previewWeek()
        DotStairs(
            columns: week.map { DotStairs.Column(filled: $0.filled, ring: $0.isFinish ? rows - 1 : nil, dimmed: $0.afterFinish) },
            rows: rows,
            dot: 14,
            spacing: 6,
            columnSpacing: 26,
            labels: week.map(\.letter)
        )
    }

    private struct Day {
        let letter: String
        let filled: Int
        let isFinish: Bool
        let afterFinish: Bool
    }

    /// A sample week from next Monday, laid out with the real pacing math.
    private func previewWeek() -> [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let monday = calendar.nextDate(after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? today
        let end = calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
        let schedule = PaceSchedule(plan: plan, window: UsageWindow(usedPercent: 0, resetsAt: end, length: UsageWindow.week), calendar: calendar)
        let finishDay = calendar.startOfDay(for: schedule.finishBy)
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let spent = schedule.expectedPercent(at: next) / 100
            let filled = Int((spent * Double(rows)).rounded())
            return Day(
                letter: calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1],
                filled: day == finishDay && filled >= rows ? rows - 1 : filled,
                isFinish: day == finishDay,
                afterFinish: day > finishDay
            )
        }
    }
}
