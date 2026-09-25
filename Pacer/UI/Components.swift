import SwiftUI

/// Planned and actual spend per day. Soft bars are the plan, solid bars are what you used.
/// Days that went well past the plan turn red.
struct WeekStrip: View {
    let bars: [DayBar]
    let provider: Provider
    var height: CGFloat = 38
    var showsValues = false

    /// Bars grow up one after another when the strip appears.
    @State private var grown = false

    var body: some View {
        let scale = max(bars.map { max($0.planned, $0.actual) }.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: showsValues ? 12 : 6) {
            ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                VStack(spacing: 6) {
                    if showsValues {
                        if bar.isToday {
                            Text("NOW")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(Theme.canvas)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.ink, in: Capsule())
                        }
                        Text(label(for: bar))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(isOver(bar) ? Theme.hot : bar.isPast || bar.isToday ? Theme.ink : Theme.muted)
                    }
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(bar.isSpendingDay ? Theme.wash(provider) : Theme.quietWash)
                            .frame(height: max(3, height * bar.planned / scale * (grown ? 1 : 0)))
                        if bar.actual >= 0.3 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isOver(bar) ? Theme.hot : Theme.tint(provider))
                                .frame(height: max(3, height * bar.actual / scale * (grown ? 1 : 0)))
                        }
                    }
                    .frame(maxWidth: showsValues ? 30 : 14)
                    .frame(height: height, alignment: .bottom)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.25 + Double(index) * 0.05), value: grown)
                    Text(bar.letter)
                        .font(.system(size: 10, weight: bar.isToday ? .bold : .regular))
                        .foregroundStyle(bar.isToday ? Theme.ink : Theme.muted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { grown = true }
    }

    private func isOver(_ bar: DayBar) -> Bool {
        (bar.isPast || bar.isToday) && bar.actual > bar.planned * 1.1 + 1
    }

    private func label(for bar: DayBar) -> String {
        if bar.isPast || bar.isToday { return Format.percent(bar.actual) }
        return bar.isSpendingDay ? Format.percent(bar.planned) : "·"
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .good: Theme.slack
        case .bad: Theme.hot
        case .neutral: Theme.muted
        case .accent: Theme.accent
        }
    }

    var wash: Color {
        switch self {
        case .neutral: Theme.quietWash
        default: color.opacity(0.14)
        }
    }
}

/// Primary and secondary buttons in the calm style.
struct PillButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .foregroundStyle(prominent ? .white : Theme.ink)
            .background(prominent ? Theme.accent : Theme.quietWash, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Toggle chips for the days you plan to spend on.
struct WeekdayChips: View {
    @Binding var selection: Set<Int>

    /// Monday first.
    private let order = [2, 3, 4, 5, 6, 7, 1]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { weekday in
                let on = selection.contains(weekday)
                Button {
                    if on { selection.remove(weekday) } else { selection.insert(weekday) }
                } label: {
                    Text(Calendar.current.shortWeekdaySymbols[weekday - 1].prefix(2))
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 34, height: 28)
                        .foregroundStyle(on ? .white : Theme.muted)
                        .background(on ? Theme.accent : Theme.quietWash, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FinishPicker: View {
    @Binding var weekday: Int?

    var body: some View {
        Picker("Finish by", selection: $weekday) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                Text(Calendar.current.weekdaySymbols[day - 1]).tag(Optional(day))
            }
            Divider()
            Text("When it resets").tag(Int?.none)
        }
        .labelsHidden()
        .fixedSize()
    }
}
