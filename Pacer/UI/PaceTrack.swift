import SwiftUI

/// The week as a race against your plan.
///
/// The glowing mountain is what you've used so far. The dashed gray line is the plan, your pacer.
/// The dashed colored line is where the current pace takes you: into the ceiling early (red)
/// or short of the target (green).
struct PaceTrack: View {
    let usage: ProviderUsage
    let report: PaceReport
    let now: Date
    var showsDays = true

    @State private var reveal = 0.0
    @State private var pulse = false

    private var tint: Color { Theme.tint(report.provider) }

    private var forecastColor: Color {
        switch report.state {
        case .hot, .out: Theme.hot
        case .slack: Theme.slack
        default: tint
        }
    }

    var body: some View {
        GeometryReader { geo in
            let frame = TrackFrame(size: geo.size, start: usage.weekly.start, end: report.resetsAt, bottom: showsDays ? 16 : 2)
            ZStack(alignment: .topLeading) {
                dotGrid(frame)
                days(frame)

                line(from: 0, frame.y(100), to: geo.size.width, frame.y(100))
                    .stroke(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                path(planPoints(), frame)
                    .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))

                area(actualPoints(), frame)
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.75), Theme.tintSoft(report.provider).opacity(0.35), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .opacity(reveal)

                path(actualPoints(), frame)
                    .trim(from: 0, to: reveal)
                    .stroke(
                        LinearGradient(colors: [Theme.tintSoft(report.provider), tint], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: tint.opacity(0.6), radius: 5)

                let forecast = forecastPoints()
                if forecast.count > 1 {
                    path(forecast, frame)
                        .stroke(forecastColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))
                        .opacity(reveal)
                    finish(forecast, frame)
                }

                halo(color: tint)
                    .position(x: frame.x(now), y: frame.y(report.used))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) { reveal = 1 }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    // MARK: - Marks

    /// Where the forecast ends: a red burst at the ceiling, or a green gap below the target.
    @ViewBuilder
    private func finish(_ forecast: [(Date, Double)], _ frame: TrackFrame) -> some View {
        if let last = forecast.last {
            if last.1 >= 99.5 {
                halo(color: Theme.hot)
                    .position(x: frame.x(last.0), y: frame.y(100))
                    .opacity(reveal)
            } else if report.target - last.1 >= 1 {
                let x = frame.x(last.0)
                ZStack {
                    line(from: x, frame.y(last.1), to: x, frame.y(report.target))
                        .stroke(Theme.slack, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    Circle().fill(Theme.slack).frame(width: 5, height: 5).position(x: x, y: frame.y(last.1))
                    Circle().strokeBorder(Theme.slack, lineWidth: 1.5).frame(width: 7, height: 7).position(x: x, y: frame.y(report.target))
                }
                .opacity(reveal)
            }
        }
    }

    private func halo(color: Color) -> some View {
        ZStack {
            Circle().fill(color.opacity(0.25)).frame(width: 18, height: 18).scaleEffect(pulse ? 1.25 : 0.8)
            Circle().fill(color).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: color.opacity(0.8), radius: 4)
        }
    }

    /// A faint dot matrix, so the chart reads as a surface rather than empty space.
    private func dotGrid(_ frame: TrackFrame) -> some View {
        Canvas { context, size in
            let step: CGFloat = 8
            let bottom = frame.y(0)
            var y = frame.y(100)
            while y <= bottom + 0.5 {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(.primary.opacity(0.1)))
                    x += step
                }
                y += step
            }
        }
    }

    @ViewBuilder
    private func days(_ frame: TrackFrame) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let starts = stride(from: 0, to: 8, by: 1).compactMap {
            calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: frame.start))
        }
        ForEach(starts, id: \.self) { day in
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            if day > frame.start, day < frame.end {
                line(from: frame.x(day), frame.y(100), to: frame.x(day), frame.y(0))
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
            let left = frame.x(max(day, frame.start))
            let right = frame.x(min(next, frame.end))
            if showsDays, right - left >= 14 {
                let mid = (left + right) / 2
                Text(calendar.veryShortWeekdaySymbols[calendar.component(.weekday, from: day) - 1])
                    .font(.system(size: 9, weight: day == today ? .bold : .medium))
                    .foregroundStyle(day == today ? Color.primary : Color.secondary)
                    .position(x: mid, y: frame.size.height - 6)
            }
        }
    }

    // MARK: - Data

    private func actualPoints() -> [(Date, Double)] {
        let start = usage.weekly.start
        let history = usage.history
            .filter { $0.date > start && $0.date < now }
            .sorted { $0.date < $1.date }
            .map { ($0.date, min($0.usedPercent, report.used)) }
        return [(start, 0)] + history + [(now, report.used)]
    }

    private func planPoints() -> [(Date, Double)] {
        sample(from: usage.weekly.start, to: report.resetsAt, count: 120) { report.schedule.expectedPercent(at: $0) }
    }

    /// The current ratio to plan, carried forward to the finish or the ceiling.
    private func forecastPoints() -> [(Date, Double)] {
        guard report.expected >= 1, now < report.finishBy, [.hot, .slack, .onPace].contains(report.state) else { return [] }
        let ratio = report.used / report.expected
        let end = min(report.runOutAt ?? report.finishBy, report.finishBy)
        var points = sample(from: now, to: end, count: 60) { min(100, max(report.used, ratio * report.schedule.expectedPercent(at: $0))) }
        if let runOut = report.runOutAt, runOut <= report.finishBy {
            points.append((runOut, 100))
        }
        return points
    }

    private func sample(from start: Date, to end: Date, count: Int, _ value: (Date) -> Double) -> [(Date, Double)] {
        guard end > start else { return [] }
        let span = end.timeIntervalSince(start)
        return (0...count).map { index in
            let date = start.addingTimeInterval(span * Double(index) / Double(count))
            return (date, value(date))
        }
    }

    // MARK: - Geometry

    private func path(_ points: [(Date, Double)], _ frame: TrackFrame) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let p = CGPoint(x: frame.x(point.0), y: frame.y(point.1))
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    private func area(_ points: [(Date, Double)], _ frame: TrackFrame) -> Path {
        var area = path(points, frame)
        guard let first = points.first, let last = points.last else { return area }
        area.addLine(to: CGPoint(x: frame.x(last.0), y: frame.y(0)))
        area.addLine(to: CGPoint(x: frame.x(first.0), y: frame.y(0)))
        area.closeSubpath()
        return area
    }

    private func line(from x1: CGFloat, _ y1: CGFloat, to x2: CGFloat, _ y2: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
        }
    }
}

private struct TrackFrame {
    let size: CGSize
    let start: Date
    let end: Date
    let bottom: CGFloat
    /// Room above the ceiling for the glow of a dot sitting on it.
    let top: CGFloat = 8

    func x(_ date: Date) -> CGFloat {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return size.width * CGFloat(min(max(date.timeIntervalSince(start) / span, 0), 1))
    }

    func y(_ percent: Double) -> CGFloat {
        let height = size.height - top - bottom
        return top + height * CGFloat(1 - min(max(percent, 0), 100) / 100)
    }
}
