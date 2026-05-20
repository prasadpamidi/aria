import Aria
import Foundation

// MARK: - CalendarRemindersCapability

/// EventKit-backed access to calendar events and reminders. The
/// real backend lives in `EventKitCalendarBackend`; tests inject
/// `InMemoryCalendarBackend` so the test runner never needs
/// EventKit authorization.
///
/// Three methods:
///
///   * `eventsToday()` — events whose window overlaps the user's
///     local "today" (midnight-to-midnight). The common Daily
///     Brief path.
///   * `eventsBetween(start, end)` — arbitrary ISO-8601 window.
///   * `upcomingReminders(limit)` — incomplete reminders sorted
///     by due date (no-due-date sorts last). Limit defaults to
///     5; cap at 50 to avoid pathological returns.
///
/// First-use authorization: the capability calls
/// `backend.requestAccess()` lazily before its first read so the
/// system permission sheet shows in context. Subsequent calls
/// short-circuit on the cached granted state.
public actor CalendarRemindersCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any CalendarBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .calendar
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
        case "eventsToday":
            return try await self.handleEventsToday()
        case "eventsBetween":
            return try await self.handleEventsBetween(arguments: arguments)
        case "upcomingReminders":
            return try await self.handleUpcomingReminders(arguments: arguments)
        default:
            throw CapabilityError.unknownMethod(capability: .calendar, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = [
        "eventsToday",
        "eventsBetween",
        "upcomingReminders",
    ]

    /// Default reminder fetch limit when the caller doesn't pass
    /// one. Mirrors what a "Daily Brief" sized workflow wants —
    /// long enough to be useful, short enough that the model's
    /// context doesn't get flooded.
    static let defaultReminderLimit = 5
    static let maxReminderLimit = 50

    // MARK: Private

    private static nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let backend: any CalendarBackend
    private var didRequestAccess = false

    // MARK: - Encoding helpers

    private static func encodeEvent(_ event: CalendarEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "title": .string(event.title),
            "start": .string(Self.formatISO8601(event.start)),
            "end": .string(Self.formatISO8601(event.end)),
            "isAllDay": .bool(event.isAllDay),
        ]
        if let location = event.location {
            object["location"] = .string(location)
        }
        if let notes = event.notes {
            object["notes"] = .string(notes)
        }
        if let calendar = event.calendar {
            object["calendar"] = .string(calendar)
        }
        return .object(object)
    }

    private static func encodeReminder(_ reminder: CalendarReminder) -> JSONValue {
        var object: [String: JSONValue] = [
            "title": .string(reminder.title),
            "isCompleted": .bool(reminder.isCompleted),
        ]
        if let due = reminder.dueDate {
            object["dueDate"] = .string(Self.formatISO8601(due))
        }
        if let list = reminder.list {
            object["list"] = .string(list)
        }
        return .object(object)
    }

    private static func todayBounds() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        // Adding 86_400 isn't always exactly "next midnight" due
        // to DST; ask the calendar for the next start-of-day so
        // workflows in DST-transition windows still bracket the
        // right day.
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start, end)
    }

    private static func formatISO8601(_ date: Date) -> String {
        self.iso8601Formatter.string(from: date)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        self.iso8601Formatter.date(from: string)
    }

    private static func requireStringArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> String {
        guard let value = arguments[key] else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string",
                actual: "missing"
            )
        }
        guard case let .string(string) = value else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string",
                actual: String(describing: value)
            )
        }
        return string
    }

    private static func optionalIntArg(
        _ key: String,
        from arguments: [String: JSONValue]
    ) -> Int? {
        guard let value = arguments[key] else {
            return nil
        }
        switch value {
        case let .integer(int): return Int(int)
        case let .number(double): return Int(double)
        case let .string(string): return Int(string)
        default: return nil
        }
    }

    /// One-shot per actor lifetime. Subsequent calls return
    /// immediately — re-asking the system every time is both
    /// noisy and pointless once the user has answered.
    private func ensureAuthorized() async throws {
        guard !self.didRequestAccess else {
            return
        }
        do {
            try await self.backend.requestAccess()
            self.didRequestAccess = true
        } catch {
            throw CapabilityError.unavailable(reason: String(describing: error))
        }
    }

    private func handleEventsToday() async throws -> JSONValue {
        let (start, end) = Self.todayBounds()
        let events = try await self.backend.events(start: start, end: end)
        return .array(events.map(Self.encodeEvent))
    }

    private func handleEventsBetween(arguments: [String: JSONValue]) async throws -> JSONValue {
        let startISO = try Self.requireStringArg("start", from: arguments, method: "eventsBetween")
        let endISO = try Self.requireStringArg("end", from: arguments, method: "eventsBetween")
        guard let start = Self.parseISO8601(startISO),
              let end = Self.parseISO8601(endISO),
              start < end else {
            throw CapabilityError.invalidArguments(
                method: "eventsBetween",
                expected: "ISO-8601 strings with start < end",
                actual: "start=\(startISO), end=\(endISO)"
            )
        }
        let events = try await self.backend.events(start: start, end: end)
        return .array(events.map(Self.encodeEvent))
    }

    private func handleUpcomingReminders(arguments: [String: JSONValue]) async throws -> JSONValue {
        let limit = Self.optionalIntArg("limit", from: arguments) ?? Self.defaultReminderLimit
        let clamped = max(1, min(limit, Self.maxReminderLimit))
        let reminders = try await self.backend.upcomingReminders(limit: clamped)
        return .array(reminders.map(Self.encodeReminder))
    }
}
