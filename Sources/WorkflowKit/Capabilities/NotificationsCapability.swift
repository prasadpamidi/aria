import Aria
import Foundation

// MARK: - NotificationsCapability

/// Local notification scheduling via `UNUserNotificationCenter`.
/// Four methods:
///
///   * `schedule({ title, body, fireAt, identifier?, sound? })` —
///     schedule for a specific ISO-8601 instant.
///   * `scheduleIn({ title, body, secondsFromNow, identifier?,
///     sound? })` — convenience for "remind me in N seconds."
///   * `cancel({ identifier })` — drop a pending notification
///     by id. Idempotent.
///   * `pending()` — list pending notification ids.
///
/// First-use authorization runs lazily on the first call.
/// Works in both interactive and background contexts —
/// scheduling doesn't need a foreground window, so workflows
/// invoked via Shortcuts / Siri can fire-and-forget.
public actor NotificationsCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any NotificationsBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .notifications
    }

    public nonisolated var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        try await self.ensureAuthorized()
        switch method {
        case "schedule":
            return try await self.handleSchedule(arguments: arguments)
        case "scheduleIn":
            return try await self.handleScheduleIn(arguments: arguments)
        case "cancel":
            return try await self.handleCancel(arguments: arguments)
        case "pending":
            return try await self.handlePending()
        default:
            throw CapabilityError.unknownMethod(capability: .notifications, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = ["schedule", "scheduleIn", "cancel", "pending"]

    // MARK: Private

    private static nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let backend: any NotificationsBackend
    private var didRequestAuthorization = false

    // MARK: - Arg helpers

    private static func requireStringArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> String {
        guard case let .string(value) = arguments[key] else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string",
                actual: String(describing: arguments[key] ?? .null)
            )
        }
        return value
    }

    private static func requireIntArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> Int {
        guard let value = arguments[key] else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of integer type",
                actual: "missing"
            )
        }
        switch value {
        case let .integer(int): return Int(int)
        case let .number(double): return Int(double)
        case let .string(string):
            if let int = Int(string) {
                return int
            }
            fallthrough
        default:
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of integer type",
                actual: String(describing: value)
            )
        }
    }

    private static func optionalStringArg(
        _ key: String,
        from arguments: [String: JSONValue]
    ) -> String? {
        guard case let .string(value) = arguments[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func optionalBoolArg(
        _ key: String,
        from arguments: [String: JSONValue],
        default defaultValue: Bool
    ) -> Bool {
        if case let .bool(value) = arguments[key] {
            return value
        }
        return defaultValue
    }

    private func ensureAuthorized() async throws {
        guard !self.didRequestAuthorization else {
            return
        }
        do {
            let granted = try await self.backend.requestAuthorization()
            self.didRequestAuthorization = true
            if !granted {
                throw CapabilityError.unavailable(reason: NotificationsError.permissionDenied.localizedDescription)
            }
        } catch let error as CapabilityError {
            throw error
        } catch {
            throw CapabilityError.unavailable(reason: String(describing: error))
        }
    }

    private func handleSchedule(arguments: [String: JSONValue]) async throws -> JSONValue {
        let title = try Self.requireStringArg("title", from: arguments, method: "schedule")
        let body = try Self.requireStringArg("body", from: arguments, method: "schedule")
        let fireAtISO = try Self.requireStringArg("fireAt", from: arguments, method: "schedule")
        guard let fireAt = Self.iso8601Formatter.date(from: fireAtISO) else {
            throw CapabilityError.invalidArguments(
                method: "schedule",
                expected: "ISO-8601 fireAt",
                actual: fireAtISO
            )
        }
        guard fireAt > Date() else {
            throw CapabilityError.invalidArguments(
                method: "schedule",
                expected: "fireAt in the future",
                actual: fireAtISO
            )
        }
        let identifier = Self.optionalStringArg("identifier", from: arguments) ?? UUID().uuidString
        let sound = Self.optionalBoolArg("sound", from: arguments, default: true)
        try await self.backend.schedule(ScheduledNotification(
            identifier: identifier,
            title: title,
            body: body,
            fireAt: fireAt,
            sound: sound
        ))
        return .object(["identifier": .string(identifier)])
    }

    private func handleScheduleIn(arguments: [String: JSONValue]) async throws -> JSONValue {
        let title = try Self.requireStringArg("title", from: arguments, method: "scheduleIn")
        let body = try Self.requireStringArg("body", from: arguments, method: "scheduleIn")
        let seconds = try Self.requireIntArg("secondsFromNow", from: arguments, method: "scheduleIn")
        guard seconds > 0 else {
            throw CapabilityError.invalidArguments(
                method: "scheduleIn",
                expected: "secondsFromNow > 0",
                actual: "\(seconds)"
            )
        }
        let identifier = Self.optionalStringArg("identifier", from: arguments) ?? UUID().uuidString
        let sound = Self.optionalBoolArg("sound", from: arguments, default: true)
        try await self.backend.schedule(ScheduledNotification(
            identifier: identifier,
            title: title,
            body: body,
            fireAt: Date().addingTimeInterval(TimeInterval(seconds)),
            sound: sound
        ))
        return .object(["identifier": .string(identifier)])
    }

    private func handleCancel(arguments: [String: JSONValue]) async throws -> JSONValue {
        let identifier = try Self.requireStringArg("identifier", from: arguments, method: "cancel")
        await self.backend.cancel(identifier: identifier)
        return .object(["ok": .bool(true)])
    }

    private func handlePending() async throws -> JSONValue {
        let identifiers = await self.backend.pending()
        return .object(["identifiers": .array(identifiers.map { .string($0) })])
    }
}
