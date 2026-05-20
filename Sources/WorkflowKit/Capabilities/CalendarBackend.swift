import Foundation

// MARK: - CalendarBackend

/// Injection seam for EventKit. Production
/// `CalendarRemindersCapability` uses `EventKitCalendarBackend`;
/// tests use `InMemoryCalendarBackend` so the runner doesn't
/// need calendar/reminder authorization at unit-test time.
public protocol CalendarBackend: Sendable {
    /// Trigger any first-use authorization prompts. May no-op if
    /// access is already granted. Throws when the user denies or
    /// the store can't be reached.
    func requestAccess() async throws

    /// Events visible in the window `[start, end)` across all
    /// authorized calendars.
    func events(start: Date, end: Date) async throws -> [CalendarEvent]

    /// Up to `limit` incomplete reminders sorted by due date
    /// (no due date sorts last). `nil` for any reminder field
    /// the backend doesn't know about.
    func upcomingReminders(limit: Int) async throws -> [CalendarReminder]
}

// MARK: - CalendarEvent

/// Backend-neutral representation of one event. EventKit's
/// `EKEvent` carries 50+ fields; we surface only the ones a
/// workflow LLM step is likely to interpolate.
public struct CalendarEvent: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        notes: String? = nil,
        calendar: String? = nil,
        isAllDay: Bool = false
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.calendar = calendar
        self.isAllDay = isAllDay
    }

    // MARK: Public

    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let notes: String?
    public let calendar: String?
    public let isAllDay: Bool
}

// MARK: - CalendarReminder

public struct CalendarReminder: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        title: String,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        list: String? = nil
    ) {
        self.title = title
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.list = list
    }

    // MARK: Public

    public let title: String
    public let dueDate: Date?
    public let isCompleted: Bool
    public let list: String?
}

// MARK: - InMemoryCalendarBackend

/// Test-only deterministic backend. Set fixtures via the
/// initialiser; reads are synchronous reads from the captured
/// state. Thread-safe by construction (immutable).
public struct InMemoryCalendarBackend: CalendarBackend {
    // MARK: Lifecycle

    public init(
        events: [CalendarEvent] = [],
        reminders: [CalendarReminder] = [],
        authorizationError: (any Error)? = nil
    ) {
        self.eventsFixture = events
        self.remindersFixture = reminders
        self.authorizationError = authorizationError
    }

    // MARK: Public

    // MARK: CalendarBackend

    public func requestAccess() async throws {
        if let error = authorizationError {
            throw error
        }
    }

    public func events(start: Date, end: Date) async throws -> [CalendarEvent] {
        self.eventsFixture
            .filter { event in
                event.start < end && event.end > start
            }
            .sorted { $0.start < $1.start }
    }

    public func upcomingReminders(limit: Int) async throws -> [CalendarReminder] {
        let pending = self.remindersFixture.filter { !$0.isCompleted }
        let sorted = pending.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case let (left?, right?): left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): false
            }
        }
        return Array(sorted.prefix(limit))
    }

    // MARK: Private

    private let eventsFixture: [CalendarEvent]
    private let remindersFixture: [CalendarReminder]
    private let authorizationError: (any Error)?
}
