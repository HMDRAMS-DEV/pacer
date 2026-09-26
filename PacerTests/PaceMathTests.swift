import Foundation
import Testing
@testable import Pacer

/// All scenarios use a UTC week that runs Sun Sep 20 12:00 to Sun Sep 27 12:00, 2026.
struct PaceMathTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ string: String) -> Date { Dates.parseISO(string)! }

    func window(used: Double = 0) -> UsageWindow {
        UsageWindow(usedPercent: used, resetsAt: date("2026-09-27T12:00:00Z"), length: UsageWindow.week)
    }

    func report(used: Double, at now: String, plan: PacePlan = PacePlan()) -> PaceReport {
        PaceReport(provider: .claude, window: window(used: used), plan: plan, now: date(now), calendar: calendar)
    }

    @Test func finishesAtEndOfFridayWorkday() {
        let schedule = PaceSchedule(plan: PacePlan(), window: window(), calendar: calendar)
        #expect(schedule.finishBy == date("2026-09-25T18:00:00Z"))
    }

    @Test func finishAtResetUsesWholeWindow() {
        var plan = PacePlan()
        plan.finishWeekday = nil
        let schedule = PaceSchedule(plan: plan, window: window(), calendar: calendar)
        #expect(schedule.finishBy == date("2026-09-27T12:00:00Z"))
    }

    @Test func evenPlanSharesWorkdaysEqually() {
        let schedule = PaceSchedule(plan: PacePlan(), window: window(), calendar: calendar)
        let shares = schedule.days.filter { $0.share > 0 }.map(\.share)
        #expect(shares.count == 5)
        #expect(shares.allSatisfy { abs($0 - 0.2) < 1e-9 })
    }

    @Test func plannedFractionInterpolatesWithinTheDay() {
        let schedule = PaceSchedule(plan: PacePlan(), window: window(), calendar: calendar)
        #expect(abs(schedule.plannedFraction(at: date("2026-09-23T18:00:00Z")) - 0.6) < 1e-9)
        #expect(abs(schedule.plannedFraction(at: date("2026-09-23T13:30:00Z")) - 0.5) < 1e-9)
        #expect(schedule.plannedFraction(at: date("2026-09-26T12:00:00Z")) == 1)
    }

    @Test func frontLoadedFavorsEarlyDays() {
        var plan = PacePlan()
        plan.shape = .frontLoaded
        let shares = PaceSchedule(plan: plan, window: window(), calendar: calendar).days.map(\.share).filter { $0 > 0 }
        #expect(shares.first! > shares.last!)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
    }

    @Test func freshFrontLoadedCopyMatchesDailyTargets() {
        var plan = PacePlan()
        plan.shape = .frontLoaded
        let report = report(used: 2, at: "2026-09-20T13:00:00Z", plan: plan)
        #expect(report.state == .fresh)
        #expect(report.band(now: date("2026-09-20T13:00:00Z")).text == "Aim for 30% Mon, then taper")
        #expect(report.detail(now: date("2026-09-20T13:00:00Z")) == "Plan starts at 30% Monday and tapers to 10% Friday.")
    }

    @Test func freshBackLoadedCopyMatchesDailyTargets() {
        var plan = PacePlan()
        plan.shape = .backLoaded
        let now = date("2026-09-20T13:00:00Z")
        let report = report(used: 2, at: "2026-09-20T13:00:00Z", plan: plan)
        #expect(report.band(now: now).text == "Aim for 10% Mon, then build")
        #expect(report.detail(now: now) == "Plan starts at 10% Monday and builds to 30% Friday.")
    }

    @Test func noSpendingDaysFallsBackToWholeWindow() {
        var plan = PacePlan()
        plan.activeWeekdays = []
        let schedule = PaceSchedule(plan: plan, window: window(), calendar: calendar)
        #expect(abs(schedule.days.map(\.share).reduce(0, +) - 1) < 1e-9)
    }

    @Test func onPaceShowsTodaysAllowance() {
        let report = report(used: 50, at: "2026-09-23T13:30:00Z")
        #expect(report.state == .onPace)
        #expect(abs(report.todayLeft - 10) < 1e-9)
        #expect(abs(report.perDayAfterToday - 20) < 1e-9)
    }

    @Test func runningHotProjectsRunOutTime() {
        // Expected 60% by Wednesday evening, used 75%: 1.25x the plan hits 100% at 80% of the plan.
        let report = report(used: 75, at: "2026-09-23T18:00:00Z")
        #expect(report.state == .hot)
        #expect(abs(report.runOutAt!.timeIntervalSince(date("2026-09-24T18:00:00Z"))) < 1)
        #expect(abs(report.projectedAtFinish! - 125) < 1e-9)
    }

    @Test func slackSuggestsLeaningIn() {
        let report = report(used: 30, at: "2026-09-23T18:00:00Z")
        #expect(report.state == .slack)
        #expect(report.runOutAt == nil)
        #expect(abs(report.projectedAtFinish! - 50) < 1e-9)
        #expect(abs(report.perDayAfterToday - 35) < 1e-9)
    }

    @Test func earlyInTheWeekIsFresh() {
        let report = report(used: 1, at: "2026-09-21T09:30:00Z")
        #expect(report.state == .fresh)
        #expect(report.projectedAtFinish == nil)
    }

    @Test func pastFinishWithLeftoverIsSlack() {
        let report = report(used: 80, at: "2026-09-26T10:00:00Z")
        #expect(report.state == .slack)
        #expect(report.projectedAtFinish == 80)
    }

    @Test func fullLimitIsOut() {
        #expect(report(used: 100, at: "2026-09-24T10:00:00Z").state == .out)
    }

    @Test func parsesMicrosecondTimestamps() {
        let parsed = Dates.parseISO("2026-09-27T16:00:00.135989+00:00")!
        #expect(abs(parsed.timeIntervalSince(date("2026-09-27T16:00:00Z")) - 0.135989) < 1e-6)
        #expect(Dates.parseISO("2026-11-05T07:59:00+00:00") == date("2026-11-05T07:59:00Z"))
    }

    @Test func dailySpendComesFromHistory() {
        let usage = ProviderUsage(
            weekly: window(used: 40),
            history: [
                UsagePoint(date: date("2026-09-21T15:00:00Z"), usedPercent: 10),
                UsagePoint(date: date("2026-09-22T15:00:00Z"), usedPercent: 25),
                UsagePoint(date: date("2026-09-23T10:00:00Z"), usedPercent: 40),
            ],
            observedAt: date("2026-09-23T10:00:00Z"),
            historyIsEstimated: false
        )
        #expect(usage.spent(from: date("2026-09-22T00:00:00Z"), to: date("2026-09-23T00:00:00Z")) == 15)
        #expect(usage.spent(from: date("2026-09-20T00:00:00Z"), to: date("2026-09-21T00:00:00Z")) == 0)
    }

    @Test func countdownFormatsLikeAFlightBoard() {
        let now = date("2026-09-23T12:00:00Z")
        #expect(Format.countdown(to: now.addingTimeInterval(45 * 60), now: now) == "45m")
        #expect(Format.countdown(to: now.addingTimeInterval(3 * 3600 + 49 * 60), now: now) == "3h 49m")
        #expect(Format.countdown(to: now.addingTimeInterval(28 * 3600), now: now) == "1d 4h")
        #expect(Format.countdown(to: now.addingTimeInterval(-60), now: now) == "0m")
    }
}
