import SwiftUI

/// The week as a dot matrix. Each column is a slice of time and each dot is a tenth of the limit.
///
/// Past columns are solid dots for what you used, red where that ran past the plan, with rings for
/// plan you left unused. Future columns are two dotted lines: faded dots for where the current
/// pace goes (red at the top if it runs out) and rings for the plan.
struct PaceDots: View {
    let usage: ProviderUsage
    let report: PaceReport
    let now: Date
    var rows = 10

    @State private var progress = 0.0
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let grid = DotGrid(size: geo.size, rows: rows, labelHeight: 14)
            let series = PaceSeries(usage: usage, report: report, now: now)
            ZStack(alignment: .topLeading) {
                DotField(grid: grid, series: series, tint: Theme.tint(report.provider), progress: progress)
                labels(grid)
                if let dot = grid.nowDot(series: series) {
                    Circle()
                        .fill(Theme.tint(report.provider).opacity(0.3))
                        .frame(width: grid.diameter * 2, height: grid.diameter * 2)
                        .scaleEffect(pulse ? 1.2 : 0.7)
                        .position(dot)
                        .opacity(progress)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { progress = 1 }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder
    private func labels(_ grid: DotGrid) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = usage.weekly.start
        let end = report.resetsAt
        let days = (0..<8).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: start)) }
        ForEach(days, id: \.self) { day in
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let left = grid.x(for: max(day, start), start: start, end: end)
            let right = grid.x(for: min(next, end), start: start, end: end)
            if right - left >= 14 {
                Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1])
                    .font(.system(size: 9, weight: day == today ? .bold : .medium))
                    .foregroundStyle(day == today ? Color.primary : Color.secondary)
                    .position(x: (left + right) / 2, y: grid.size.height - 5)
            }
        }
    }
}

/// Draws every dot. Animatable so the columns fill in left to right.
private struct DotField: View, @MainActor Animatable {
    let grid: DotGrid
    let series: PaceSeries
    let tint: Color
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            let step = 100 / Double(grid.rows)
            let shown = Int((Double(grid.columns) * progress).rounded(.up))
            for column in 0..<grid.columns {
                let date = series.date(column: column, of: grid.columns)
                let isPast = date <= series.now
                let value = isPast ? series.actual(at: date) : series.forecast(at: date)
                let plan = series.plan(at: date)
                for row in 0..<grid.rows {
                    let level = (Double(row) + 0.5) * step
                    let rect = grid.rect(column: column, row: row)
                    let mark: Mark
                    if column >= shown {
                        mark = .empty
                    } else if isPast {
                        if level <= min(value, plan) { mark = .solid(tint) }
                        else if level <= value { mark = .solid(Theme.hot) }
                        else if level <= plan { mark = .ring }
                        else { mark = .empty }
                    } else if row == top(value, step), value >= series.report.used + step / 2 {
                        // The future is two dotted lines: where this pace goes, and the plan.
                        mark = .solid((value >= 99.5 && series.runsOut ? Theme.hot : tint).opacity(0.55))
                    } else if row == top(plan, step), plan > value {
                        mark = .ring
                    } else {
                        mark = .empty
                    }
                    draw(mark, in: rect, context: &context)
                }
            }
        }
    }

    /// The highest row a value fills, or -1.
    private func top(_ value: Double, _ step: Double) -> Int {
        Int((value / step - 0.5).rounded(.down))
    }

    private enum Mark {
        case solid(Color), ring, empty
    }

    private func draw(_ mark: Mark, in rect: CGRect, context: inout GraphicsContext) {
        switch mark {
        case .solid(let color):
            context.fill(Path(ellipseIn: rect), with: .color(color))
        case .ring:
            let inset = max(0.75, rect.width * 0.08)
            context.stroke(Path(ellipseIn: rect.insetBy(dx: inset, dy: inset)), with: .color(.primary.opacity(0.35)), lineWidth: inset * 2)
        case .empty:
            let dot = rect.insetBy(dx: rect.width * 0.35, dy: rect.height * 0.35)
            context.fill(Path(ellipseIn: dot), with: .color(.primary.opacity(0.12)))
        }
    }
}

/// Square cells sized so the rows fill the height; as many columns as fit the width.
private struct DotGrid {
    let size: CGSize
    let rows: Int
    let labelHeight: CGFloat

    var pitch: CGFloat { max(4, (size.height - labelHeight) / CGFloat(rows)) }
    var columns: Int { max(1, Int(size.width / pitch)) }
    var diameter: CGFloat { pitch * 0.74 }
    private var inset: CGFloat { (size.width - pitch * CGFloat(columns)) / 2 }

    func rect(column: Int, row: Int) -> CGRect {
        let center = self.center(column: column, row: row)
        return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
    }

    func center(column: Int, row: Int) -> CGPoint {
        CGPoint(
            x: inset + pitch * (CGFloat(column) + 0.5),
            y: pitch * (CGFloat(rows - row) - 0.5)
        )
    }

    func x(for date: Date, start: Date, end: Date) -> CGFloat {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return inset }
        return inset + pitch * CGFloat(columns) * CGFloat(min(max(date.timeIntervalSince(start) / span, 0), 1))
    }

    /// The top solid dot in the column that holds now.
    func nowDot(series: PaceSeries) -> CGPoint? {
        let span = series.end.timeIntervalSince(series.start)
        guard span > 0 else { return nil }
        let column = min(columns - 1, Int(Double(columns) * series.now.timeIntervalSince(series.start) / span))
        let row = Int(series.report.used / (100 / Double(rows)) - 0.5)
        guard column >= 0, row >= 0 else { return nil }
        return center(column: column, row: min(row, rows - 1))
    }
}

/// Actual, planned, and forecast usage over the window, as percentages.
struct PaceSeries {
    let report: PaceReport
    let now: Date
    let start: Date
    let end: Date
    private let points: [(Date, Double)]

    init(usage: ProviderUsage, report: PaceReport, now: Date) {
        self.report = report
        self.now = now
        start = usage.weekly.start
        end = report.resetsAt
        let start = usage.weekly.start
        let used = report.used
        let inWindow = usage.history.filter { $0.date > start && $0.date < now }.sorted { $0.date < $1.date }
        var points: [(Date, Double)] = [(start, 0)]
        points += inWindow.map { ($0.date, min($0.usedPercent, used)) }
        points.append((now, used))
        self.points = points
    }

    var runsOut: Bool {
        report.runOutAt.map { $0 <= report.finishBy } ?? false
    }

    /// The middle of a column's slice of time.
    func date(column: Int, of columns: Int) -> Date {
        start.addingTimeInterval(end.timeIntervalSince(start) * (Double(column) + 0.5) / Double(columns))
    }

    func actual(at date: Date) -> Double {
        guard let after = points.firstIndex(where: { $0.0 >= date }) else { return report.used }
        guard after > 0 else { return points[0].1 }
        let (d0, v0) = points[after - 1]
        let (d1, v1) = points[after]
        let span = d1.timeIntervalSince(d0)
        return span > 0 ? v0 + (v1 - v0) * date.timeIntervalSince(d0) / span : v1
    }

    func plan(at date: Date) -> Double {
        report.schedule.expectedPercent(at: date)
    }

    /// The current ratio to plan carried forward, flat after the finish.
    func forecast(at date: Date) -> Double {
        guard report.expected >= 1, [.hot, .slack, .onPace].contains(report.state) else { return report.used }
        let ratio = report.used / report.expected
        return min(100, max(report.used, ratio * plan(at: min(date, report.finishBy))))
    }
}
