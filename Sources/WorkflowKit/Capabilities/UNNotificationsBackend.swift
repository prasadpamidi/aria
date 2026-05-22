import Foundation
#if canImport(UserNotifications)
    import UserNotifications

    // MARK: - UNNotificationsBackend

    /// Production notifications backend using
    /// `UNUserNotificationCenter.current()`. Wraps the
    /// completion-handler APIs in async/await so the capability
    /// surface is uniform with the other backends.
    public final class UNNotificationsBackend: NotificationsBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init() {
            self.center = UNUserNotificationCenter.current()
        }

        // MARK: Public

        public func requestAuthorization() async throws -> Bool {
            try await self.center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        public func schedule(_ notification: ScheduledNotification) async throws {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = notification.sound ? .default : nil

            let interval = max(notification.fireAt.timeIntervalSinceNow, 1)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: interval,
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: trigger
            )
            try await self.center.add(request)
        }

        public func cancel(identifier: String) async {
            self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
        }

        public func pending() async -> [String] {
            let requests = await self.center.pendingNotificationRequests()
            return requests.map(\.identifier)
        }

        // MARK: Private

        private let center: UNUserNotificationCenter
    }
#endif

// MARK: - NotificationsError

public enum NotificationsError: LocalizedError, Sendable, Equatable {
    case permissionDenied
    case fireAtInPast(Date)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Avyra wasn't granted permission to schedule notifications."
        case let .fireAtInPast(date):
            "Notification fire time is in the past: \(date). Use a future time."
        }
    }
}
