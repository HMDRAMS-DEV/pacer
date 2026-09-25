import Foundation

enum PlanShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case even, frontLoaded, backLoaded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .even: "Even"
        case .frontLoaded: "Front-loaded"
        case .backLoaded: "Back-loaded"
        }
    }

    var summary: String {
        switch self {
        case .even: "The same amount each day."
        case .frontLoaded: "More early in the week, tapering off."
        case .backLoaded: "Start light and build toward the finish."
        }
    }

    /// Relative weight of the `index`-th of `count` spending days.
    func weight(index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        let position = Double(index) / Double(count - 1)
        switch self {
        case .even: return 1
        case .frontLoaded: return 1.5 - position
        case .backLoaded: return 0.5 + position
        }
    }
}

struct PacePlan: Codable, Equatable, Sendable {
    /// Calendar weekday to finish by (1 is Sunday). `nil` spreads usage until the reset.
    var finishWeekday: Int? = 6
    var targetPercent: Double = 100
    var shape: PlanShape = .even
    var activeWeekdays: Set<Int> = [2, 3, 4, 5, 6]
    var dayStartHour: Int = 9
    var dayEndHour: Int = 18
}

struct PlanDay: Identifiable, Sendable {
    var id: Date { date }
    /// Start of the calendar day.
    let date: Date
    /// Spending interval for the day, clipped to the window and finish time.
    let start: Date
    let end: Date
    /// Fraction of the whole plan assigned to this day. Zero for rest days.
    let share: Double
}

/// Turns a plan and a usage window into an expected usage curve.
struct PaceSchedule: Sendable {
    let windowStart: Date
    let windowEnd: Date
    let finishBy: Date
    let target: Double
    let days: [PlanDay]

    init(plan: PacePlan, window: UsageWindow, calendar: Calendar = .current) {
        windowStart = window.start
        windowEnd = window.resetsAt
        target = plan.targetPercent
        let finish = Self.finishDate(plan: plan, start: window.start, end: window.resetsAt, calendar: calendar)
        finishBy = finish
        var days = Self.layout(plan: plan, start: window.start, end: window.resetsAt, finish: finish, workHoursOnly: true, calendar: calendar)
        if days.allSatisfy({ $0.share == 0 }) {
            // No working hours fall inside the window, so spread across every hour instead.
            days = Self.layout(plan: plan, start: window.start, end: window.resetsAt, finish: finish, workHoursOnly: false, calendar: calendar)
        }
        self.days = days
    }

    /// Fraction of the plan that should be spent by `date`, from 0 to 1.
    func plannedFraction(at date: Date) -> Double {
        days.reduce(0) { total, day in
            guard day.share > 0 else { return total }
            let length = day.end.timeIntervalSince(day.start)
            let progress = min(max(date.timeIntervalSince(day.start) / length, 0), 1)
            return total + day.share * progress
        }
    }

    func expectedPercent(at date: Date) -> Double {
        target * plannedFraction(at: date)
    }

    /// The moment the plan reaches `fraction`, or nil past the end of the plan.
    func date(reaching fraction: Double) -> Date? {
        var total = 0.0
        for day in days where day.share > 0 {
            if total + day.share >= fraction - 1e-9 {
                let progress = max(0, fraction - total) / day.share
                return day.start.addingTimeInterval(progress * day.end.timeIntervalSince(day.start))
            }
            total += day.share
        }
        return nil
    }

    private static func finishDate(plan: PacePlan, start: Date, end: Date, calendar: Calendar) -> Date {
        guard let weekday = plan.finishWeekday else { return end }
        let firstDay = calendar.startOfDay(for: start)
        var day = calendar.startOfDay(for: end)
        while day >= firstDay {
            if calendar.component(.weekday, from: day) == weekday {
                let dayEnd = calendar.date(byAdding: .hour, value: plan.dayEndHour, to: day) ?? day
                let finish = min(dayEnd, end)
                if finish > start { return finish }
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return end
    }

    private static func layout(
        plan: PacePlan, start: Date, end: Date, finish: Date, workHoursOnly: Bool, calendar: Calendar
    ) -> [PlanDay] {
        struct Slot { let date: Date; let start: Date; let end: Date; let available: Double; let active: Bool }

        var slots: [Slot] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let open = workHoursOnly ? calendar.date(byAdding: .hour, value: plan.dayStartHour, to: day) ?? day : day
            let close = workHoursOnly ? calendar.date(byAdding: .hour, value: plan.dayEndHour, to: day) ?? next : next
            let slotStart = max(open, start)
            let slotEnd = max(slotStart, min(close, finish))
            let fullLength = close.timeIntervalSince(open)
            let available = fullLength > 0 ? slotEnd.timeIntervalSince(slotStart) / fullLength : 0
            let weekdayOn = !workHoursOnly || plan.activeWeekdays.contains(calendar.component(.weekday, from: day))
            slots.append(Slot(date: day, start: slotStart, end: slotEnd, available: available, active: weekdayOn && available > 0))
            day = next
        }

        let activeCount = slots.filter(\.active).count
        var index = 0
        let weights = slots.map { slot -> Double in
            guard slot.active else { return 0 }
            defer { index += 1 }
            return plan.shape.weight(index: index, count: activeCount) * slot.available
        }
        let total = weights.reduce(0, +)
        return zip(slots, weights).map { slot, weight in
            PlanDay(date: slot.date, start: slot.start, end: slot.end, share: total > 0 ? weight / total : 0)
        }
    }
}

enum PaceState: Sendable {
    /// Too early in the plan to judge.
    case fresh
    case onPace
    /// Spending faster than planned.
    case hot
    /// Spending slower than planned.
    case slack
    /// The limit is used up.
    case out
    /// The plan's target is reached.
    case done
}

struct PaceReport: Sendable {
    let provider: Provider
    let used: Double
    let expected: Double
    let target: Double
    let plannedFraction: Double
    let state: PaceState
    /// Usage expected at the finish time if the current pace holds.
    let projectedAtFinish: Double?
    /// When usage reaches 100% if the current pace holds.
    let runOutAt: Date?
    /// Percent still available today under the rebalanced plan.
    let todayLeft: Double
    /// Average percent per spending day after today under the rebalanced plan.
    let perDayAfterToday: Double
    let finishBy: Date
    let resetsAt: Date
    let schedule: PaceSchedule

    init(provider: Provider, window: UsageWindow, plan: PacePlan, now: Date, calendar: Calendar = .current) {
        let schedule = PaceSchedule(plan: plan, window: window, calendar: calendar)
        let fraction = schedule.plannedFraction(at: now)
        let used = window.usedPercent
        let target = plan.targetPercent
        let expected = target * fraction

        self.provider = provider
        self.used = used
        self.expected = expected
        self.target = target
        self.plannedFraction = fraction
        self.finishBy = schedule.finishBy
        self.resetsAt = window.resetsAt
        self.schedule = schedule

        // Spread what is left over the rest of the plan, in the plan's proportions.
        let remaining = max(0, target - used)
        let remainingFraction = 1 - fraction
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let fractionByTomorrow = schedule.plannedFraction(at: tomorrow)
        let futureDays = schedule.days.filter { $0.date >= tomorrow && $0.share > 0 }.count
        if remainingFraction > 1e-6 {
            todayLeft = remaining * (fractionByTomorrow - fraction) / remainingFraction
            perDayAfterToday = futureDays > 0 ? remaining * (1 - fractionByTomorrow) / remainingFraction / Double(futureDays) : 0
        } else {
            todayLeft = 0
            perDayAfterToday = 0
        }

        // Assume the ratio between actual and planned usage holds for the rest of the plan.
        var projected: Double?
        var runOut: Date?
        if now >= schedule.finishBy {
            projected = used
        } else if fraction >= 0.05, expected > 0 {
            let ratio = used / expected
            projected = target * ratio
            if target * ratio > 100 {
                runOut = schedule.date(reaching: 100 / (target * ratio))
            }
        }
        projectedAtFinish = projected
        runOutAt = used >= 99.5 ? now : runOut

        let tolerance = max(3, expected * 0.1)
        if used >= 99.5 {
            state = .out
        } else if now >= schedule.finishBy {
            state = used >= target - 2 ? .done : .slack
        } else if used - expected > tolerance {
            state = .hot
        } else if fraction < 0.05 {
            state = .fresh
        } else if expected - used > tolerance {
            state = .slack
        } else {
            state = .onPace
        }
    }

    /// A typical day's allowance for the rest of the plan.
    var typicalDay: Double { perDayAfterToday > 0 ? perDayAfterToday : todayLeft }
}
