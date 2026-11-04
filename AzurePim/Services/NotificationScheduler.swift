import AzurePimCore
import Foundation
import UserNotifications

/// Expiry Notification (T3.9, T4.1): one local notification per activation, `lead` minutes before its end,
/// with Extend / Dismiss actions. The eligible role id travels in `userInfo`: assignment rows are recreated on
/// every refresh and their instance id changes after an extension.
@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let category = "EXPIRY"
    nonisolated static let extendAction = "EXTEND"
    nonisolated static let dismissAction = "DISMISS"
    nonisolated static let prefix = "expiry-"
    nonisolated static let roleKey = "eligibleRoleId"
    private let center = UNUserNotificationCenter.current()
    var onOpen: (() -> Void)?
    /// Runs the extension and returns the follow-up text.
    var onExtend: ((String) async -> String)?

    override init() {
        super.init()
        center.delegate = self
        // Changes privileges: needs an unlocked Mac (security review I1).
        let extend = UNNotificationAction(identifier: Self.extendAction, title: "Extend", options: [.authenticationRequired])
        let dismiss = UNNotificationAction(identifier: Self.dismissAction, title: "Dismiss", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [extend, dismiss],
                                                                 intentIdentifiers: [])])
    }

    func reschedule(activations: [ActiveAssignment], leadMinutes: Int) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        for assignment in activations {
            guard let end = assignment.endAt else { continue }
            let fireAt = end.addingTimeInterval(-Double(leadMinutes) * 60)
            guard fireAt > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(assignment.roleName) — \(assignment.scopeName)"
            content.body = "Expires at \(end.formatted(date: .omitted, time: .shortened)) (\(leadMinutes) min)."
            content.sound = .default
            if let roleId = assignment.eligibleRole?.id {
                content.categoryIdentifier = Self.category
                content.userInfo = [Self.roleKey: roleId]
            }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireAt.timeIntervalSinceNow, repeats: false)
            let id = Self.prefix + (assignment.eligibleRole?.id ?? assignment.id)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    /// Immediate notification (follow-ups, approval decisions).
    func notify(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let roleId = response.notification.request.content.userInfo[Self.roleKey] as? String
        let title = response.notification.request.content.title
        switch action {
        case Self.extendAction:
            // Awaited here: the system treats the response as handled when this method returns.
            guard let roleId else { return }
            await extend(roleId: roleId, title: title)
        case Self.dismissAction, UNNotificationDismissActionIdentifier:
            break
        default:
            await MainActor.run { onOpen?() }
        }
    }

    private func extend(roleId: String, title: String) async {
        guard let onExtend else { return }
        let text = await onExtend(roleId)
        center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + roleId])
        await notify(title: title, body: text)
    }
}
