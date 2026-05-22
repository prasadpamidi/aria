import Foundation

// MARK: - ScheduledNotification

/// Value-typed payload the backend persists when scheduling.
/// Carries everything `UNUserNotificationCenter` needs without
/// pulling UserNotifications into the public surface (keeps
/// `WorkflowKit` Linux-friendly).
public struct ScheduledNotification: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        identifier: String,
        title: String,
        body: String,
        fireAt: Date,
        sound: Bool = true
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.sound = sound
    }

    // MARK: Public

    public let identifier: String
    public let title: String
    public let body: String
    public let fireAt: Date
    /// When `false`, the notification fires silently. Useful
    /// for nudges the user has opted to make non-intrusive.
    public let sound: Bool
}

// MARK: - NotificationsBackend

/// Injection seam for `UNUserNotificationCenter`. Production
/// `NotificationsCapability` uses `UNNotificationsBackend`;
/// tests use `InMemoryNotificationsBackend` so the runner
/// never has to ask iOS for notification permission.
public protocol NotificationsBackend: Sendable {
    /// Trigger the system permission prompt. Returns `true`
    /// when the user grants alert + sound; `false` on denial.
    /// Idempotent — iOS records the user's choice once.
    func requestAuthorization() async throws -> Bool

    /// Schedule a notification. Re-using an identifier
    /// replaces the prior pending notification (iOS semantics
    /// — `add(_:)` overwrites). Throws when the system
    /// rejects the request (denied permission, malformed
    /// trigger, etc.).
    func schedule(_ notification: ScheduledNotification) async throws

    /// Cancel a pending notification by identifier. Idempotent
    /// — unknown identifiers no-op.
    func cancel(identifier: String) async

    /// Identifiers of every pending notification this app has
    /// scheduled. Useful for "did I already remind the user
    /// about X?" patterns.
    func pending() async -> [String]
}

// MARK: - InMemoryNotificationsBackend

/// Test-only backend. Holds the pending set in an actor so
/// concurrent schedules don't race. Records every authorization
/// request so tests can assert on the auth flow.
public actor InMemoryNotificationsBackend: NotificationsBackend {
    // MARK: Lifecycle

    public init(
        authorizationGranted: Bool = true,
        authorizationError: (any Error)? = nil
    ) {
        self.authorizationGranted = authorizationGranted
        self.authorizationError = authorizationError
    }

    // MARK: Public

    public private(set) var authorizationRequestCount = 0

    public func requestAuthorization() async throws -> Bool {
        self.authorizationRequestCount += 1
        if let error = self.authorizationError {
            throw error
        }
        return self.authorizationGranted
    }

    public func schedule(_ notification: ScheduledNotification) async throws {
        // Mirror iOS: identifier collisions overwrite.
        self.notifications.removeAll { $0.identifier == notification.identifier }
        self.notifications.append(notification)
    }

    public func cancel(identifier: String) async {
        self.notifications.removeAll { $0.identifier == identifier }
    }

    public func pending() async -> [String] {
        self.notifications.map(\.identifier)
    }

    /// Inspection hook for tests.
    public func pendingNotifications() -> [ScheduledNotification] {
        self.notifications
    }

    // MARK: Private

    private let authorizationGranted: Bool
    private let authorizationError: (any Error)?
    private var notifications: [ScheduledNotification] = []
}
