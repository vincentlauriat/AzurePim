import AzurePimCore
import Foundation
import UserNotifications

/// Expiry Notification (ImplementationPlan T3.9): one local notification per activation, `lead` minutes before its end.
/// The Extend action arrives with T4.1.
@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let category = "EXPIRY"
    static let prefix = "expiry-"
    private let center = UNUserNotificationCenter.current()
    var onOpen: (() -> Void)?

    override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [],
                                                                 intentIdentifiers: [])])
    }

    func reschedule(activations: [ActiveAssignment], leadMinutes: Int) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        for assignment in activations {
            guard let end = assignment.endAt else { continue }
            let fireAt = end.addingTimeInterval(-Double(leadMinutes) * 60)
            guard fireAt > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(assignment.roleName) — \(assignment.scopeName)"
            content.body = "Expires at \(formatter.string(from: end)) (\(leadMinutes) min)."
            content.categoryIdentifier = Self.category
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSinceNow, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.prefix + assignment.id, content: content, trigger: trigger))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { onOpen?() }
    }
}
