import Foundation
import UserNotifications

/// Sends at most one "ease off" and one "lean in" notification per tool per day, during working hours.
@MainActor
enum PaceAlerts {
    static func evaluate(_ reports: [PaceReport], plan: PacePlan, now: Date) {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)

        for report in reports {
            guard plan.activeWeekdays.contains(weekday),
                  (plan.dayStartHour..<plan.dayEndHour).contains(hour) else { continue }

            let kind: String
            let title: String
            if report.state == .hot, let runOut = report.runOutAt, runOut < report.finishBy {
                kind = "hot"
                title = "Ease off \(report.provider.name)"
            } else if report.state == .slack, report.plannedFraction >= 0.3,
                      let projected = report.projectedAtFinish, report.target - projected >= 15 {
                kind = "slack"
                title = "Lean into \(report.provider.name)"
            } else {
                continue
            }

            let key = "alert.\(report.provider.rawValue).\(kind)"
            let today = now.formatted(.iso8601.year().month().day())
            guard UserDefaults.standard.string(forKey: key) != today else { continue }
            UserDefaults.standard.set(today, forKey: key)

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = report.detail(now: now)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
    }
}

/// Shows notifications even while a Pacer window is in front.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
