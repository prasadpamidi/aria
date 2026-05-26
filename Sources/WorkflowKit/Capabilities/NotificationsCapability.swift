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

    /// Resolve a `fireAt` argument to an absolute `Date`. Tries
    /// the permissive ISO-8601 paths first (full timezone-bearing
    /// form, fractional seconds), then falls back to two naïve
    /// shapes interpreted in the user's local timezone. Returns
    /// `nil` if no parser matches — callers throw
    /// `invalidArguments` in that case.
    static func parseFireAt(_ raw: String) -> Date? {
        if let date = self.iso8601Formatter.date(from: raw) {
            return date
        }
        if let date = self.iso8601FractionalFormatter.date(from: raw) {
            return date
        }
        if let date = self.naiveDateTimeFormatter.date(from: raw) {
            return date
        }
        if let date = self.naiveDateTimeNoSecondsFormatter.date(from: raw) {
            return date
        }
        return nil
    }

    // MARK: Private

    private static nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Same as `iso8601Formatter` but also accepts fractional
    /// seconds (`…00:00.000Z`). Tried second.
    private static nonisolated(unsafe) let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Local-timezone parser for naïve datetimes (no `Z`, no
    /// offset). Small LLMs frequently emit `fireAt` as
    /// `"2026-05-26T18:00:00"` when they mean "6pm in the user's
    /// timezone." Without this fallback, the strict ISO parser
    /// rejects the string and the broker throws
    /// `invalidArguments`, even though the model's intent was
    /// clear. With it, we resolve the wall-clock time in
    /// `TimeZone.current` — the behaviour users expect when an
    /// agent says "I'll remind you at 6pm."
    private static nonisolated(unsafe) let naiveDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Naïve datetime without seconds — `2026-05-26T18:00`.
    /// Same local-time interpretation as the seconds-bearing
    /// variant. Tried after the fractional + plain ISO parsers.
    private static nonisolated(unsafe) let naiveDateTimeNoSecondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
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
        // `parseFireAt` is permissive: full ISO-8601 with offset
        // OR `Z` is honoured as-is; a naïve datetime
        // (`2026-05-26T18:00:00`, no timezone) is interpreted in
        // the user's local timezone. The naïve path is what
        // makes small-LLM-driven agents reliable — they
        // routinely emit `fireAt` without the offset shown in
        // the date anchor.
        guard let fireAt = Self.parseFireAt(fireAtISO) else {
            throw CapabilityError.invalidArguments(
                method: "schedule",
                expected: "ISO-8601 fireAt (with timezone, or naïve interpreted as local)",
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
