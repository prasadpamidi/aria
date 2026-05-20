import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - CalendarRemindersCapabilityTests

/// Coverage for the EventKit-backed capability using
/// `InMemoryCalendarBackend` fixtures. Real EventKit access is
/// device-only; this suite focuses on the encoding, time-window,
/// limit-clamping, and unknown-method paths the capability owns.
struct CalendarRemindersCapabilityTests {
    // MARK: Internal

    // MARK: - eventsToday

    @Test
    func eventsTodayReturnsTodaysOverlappingWindow() async throws {
        let backend = try InMemoryCalendarBackend(events: Self.windowFixtureEvents())
        let capability = CalendarRemindersCapability(backend: backend)
        let result = try await capability.call(
            method: "eventsToday",
            arguments: [:],
            context: Self.context()
        )
        let titles = Self.titles(from: result)
        // Ascending by start, so "Today AM" precedes "Today late".
        #expect(titles == ["Today AM", "Today late"])
    }

    @Test
    func eventsAreEncodedWithAllOptionalFields() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(1800)
        let backend = InMemoryCalendarBackend(events: [
            CalendarEvent(
                title: "Standup",
                start: start,
                end: end,
                location: "Conf room A",
                notes: "kick off the week",
                calendar: "Work",
                isAllDay: false
            ),
        ])

        let capability = CalendarRemindersCapability(backend: backend)
        let result = try await capability.call(
            method: "eventsBetween",
            arguments: [
                "start": .string("2027-01-15T08:00:00Z"),
                "end": .string("2027-01-15T17:00:00Z"),
            ],
            context: Self.context()
        )

        guard case let .array(events) = result,
              case let .object(first) = events.first ?? .null else {
            Issue.record("Expected one encoded event, got \(result)")
            return
        }

        #expect(first["title"] == .string("Standup"))
        #expect(first["location"] == .string("Conf room A"))
        #expect(first["notes"] == .string("kick off the week"))
        #expect(first["calendar"] == .string("Work"))
        #expect(first["isAllDay"] == .bool(false))
    }

    @Test
    func eventsBetweenRejectsInvalidWindow() async {
        let capability = CalendarRemindersCapability(backend: InMemoryCalendarBackend())

        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "eventsBetween",
                arguments: [
                    "start": .string("2027-01-15T17:00:00Z"),
                    "end": .string("2027-01-15T08:00:00Z"),
                ],
                context: Self.context()
            )
        }
    }

    @Test
    func eventsBetweenRejectsMissingArgs() async {
        let capability = CalendarRemindersCapability(backend: InMemoryCalendarBackend())

        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "eventsBetween",
                arguments: ["start": .string("2027-01-15T08:00:00Z")],
                context: Self.context()
            )
        }
    }

    // MARK: - upcomingReminders

    @Test
    func upcomingRemindersSortsByDueDateAndExcludesCompleted() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let backend = InMemoryCalendarBackend(reminders: [
            CalendarReminder(title: "later", dueDate: now.addingTimeInterval(7200)),
            CalendarReminder(title: "sooner", dueDate: now.addingTimeInterval(3600)),
            CalendarReminder(title: "done", dueDate: now, isCompleted: true),
            CalendarReminder(title: "no due", dueDate: nil),
        ])

        let capability = CalendarRemindersCapability(backend: backend)
        let result = try await capability.call(
            method: "upcomingReminders",
            arguments: [:],
            context: Self.context()
        )

        guard case let .array(items) = result else {
            Issue.record("Expected an array, got \(result)")
            return
        }
        let titles = items.compactMap { value -> String? in
            guard case let .object(dict) = value,
                  case let .string(title) = dict["title"] ?? .null else {
                return nil
            }
            return title
        }
        #expect(titles == ["sooner", "later", "no due"])
    }

    @Test
    func upcomingRemindersHonorsCustomLimit() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var reminders: [CalendarReminder] = []
        for index in 0..<8 {
            reminders.append(
                CalendarReminder(
                    title: "r\(index)",
                    dueDate: now.addingTimeInterval(TimeInterval(index * 3600))
                )
            )
        }
        let capability = CalendarRemindersCapability(
            backend: InMemoryCalendarBackend(reminders: reminders)
        )
        let result = try await capability.call(
            method: "upcomingReminders",
            arguments: ["limit": .integer(3)],
            context: Self.context()
        )

        guard case let .array(items) = result else {
            Issue.record("Expected an array, got \(result)")
            return
        }
        #expect(items.count == 3)
    }

    @Test
    func upcomingRemindersClampsHugeLimit() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reminders = (0..<100).map { index in
            CalendarReminder(
                title: "r\(index)",
                dueDate: now.addingTimeInterval(TimeInterval(index * 60))
            )
        }
        let capability = CalendarRemindersCapability(
            backend: InMemoryCalendarBackend(reminders: reminders)
        )
        let result = try await capability.call(
            method: "upcomingReminders",
            arguments: ["limit": .integer(1000)],
            context: Self.context()
        )

        guard case let .array(items) = result else {
            Issue.record("Expected an array, got \(result)")
            return
        }
        #expect(items.count == CalendarRemindersCapability.maxReminderLimit)
    }

    // MARK: - Authorization + method dispatch

    @Test
    func unknownMethodThrows() async {
        let capability = CalendarRemindersCapability(backend: InMemoryCalendarBackend())
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "futureMethod",
                arguments: [:],
                context: Self.context()
            )
        }
    }

    @Test
    func authorizationFailureSurfacesAsUnavailable() async {
        struct DummyError: Error { }
        let backend = InMemoryCalendarBackend(authorizationError: DummyError())
        let capability = CalendarRemindersCapability(backend: backend)

        await #expect {
            try await capability.call(
                method: "eventsToday",
                arguments: [:],
                context: Self.context()
            )
        } throws: { error in
            guard let capabilityError = error as? CapabilityError,
                  case .unavailable = capabilityError else {
                return false
            }
            return true
        }
    }

    // MARK: Private

    /// Mixed-window event fixture used by the "today" filter
    /// test. Built once and broken out of the test body so the
    /// test fits under the 40-line cap.
    private static func windowFixtureEvents() throws -> [CalendarEvent] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let later = try #require(calendar.date(byAdding: .hour, value: 2, to: dayStart))
        let yesterday = try #require(calendar.date(byAdding: .hour, value: -3, to: dayStart))
        let tomorrow = try #require(calendar.date(byAdding: .day, value: 2, to: dayStart))
        return [
            CalendarEvent(
                title: "Today AM",
                start: dayStart.addingTimeInterval(3600),
                end: dayStart.addingTimeInterval(7200)
            ),
            CalendarEvent(title: "Today late", start: later, end: later.addingTimeInterval(1800)),
            CalendarEvent(title: "Yesterday", start: yesterday, end: yesterday.addingTimeInterval(1800)),
            CalendarEvent(title: "Tomorrow", start: tomorrow, end: tomorrow.addingTimeInterval(1800)),
        ]
    }

    private static func titles(from result: JSONValue) -> [String] {
        guard case let .array(items) = result else {
            return []
        }
        return items.compactMap { value in
            guard case let .object(dict) = value,
                  case let .string(title) = dict["title"] ?? .null else {
                return nil
            }
            return title
        }
    }

    // MARK: - Helpers

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: "avyra.builtin.test",
            callerWorkflowID: nil,
            attended: true
        )
    }
}
