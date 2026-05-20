#if canImport(EventKit)
    import EventKit
    import Foundation

    // MARK: - EventKitCalendarBackend

    /// Production calendar/reminders backend. Wraps a single
    /// `EKEventStore` — Apple's guidance is one store per app,
    /// reused across reads, so the capability instantiates this
    /// once and shares it across calls.
    ///
    /// Authorization: iOS 17+ split the old `requestAccess` into
    /// `requestFullAccessToEvents` and
    /// `requestFullAccessToReminders`. We request both eagerly
    /// the first time `requestAccess` is called so subsequent
    /// reads don't pop another sheet mid-workflow.
    public final class EventKitCalendarBackend: CalendarBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init(store: EKEventStore = EKEventStore()) {
            self.store = store
        }

        // MARK: Public

        // MARK: CalendarBackend

        public func requestAccess() async throws {
            // Both requests are independent — running them
            // concurrently keeps the first-run wait short.
            async let events: Void = self.requestFullAccessToEvents()
            async let reminders: Void = self.requestFullAccessToReminders()
            _ = try await (events, reminders)
        }

        public func events(start: Date, end: Date) async throws -> [CalendarEvent] {
            let predicate = self.store.predicateForEvents(
                withStart: start,
                end: end,
                calendars: nil
            )
            return self.store
                .events(matching: predicate)
                .map(Self.mapEvent)
                .sorted { $0.start < $1.start }
        }

        public func upcomingReminders(limit: Int) async throws -> [CalendarReminder] {
            let predicate = self.store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: nil,
                calendars: nil
            )
            // Map inside the completion handler so the continuation
            // only carries `[CalendarReminder]` (Sendable) across
            // the boundary — `[EKReminder]` isn't Sendable under
            // strict Swift 6 concurrency.
            let mapped: [CalendarReminder] = try await withCheckedThrowingContinuation { continuation in
                self.store.fetchReminders(matching: predicate) { reminders in
                    let safe = (reminders ?? []).map(Self.mapReminder)
                    continuation.resume(returning: safe)
                }
            }
            let sorted = mapped.sorted { lhs, rhs in
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

        private let store: EKEventStore

        private static func mapEvent(_ event: EKEvent) -> CalendarEvent {
            CalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                location: event.location,
                notes: event.notes,
                calendar: event.calendar?.title,
                isAllDay: event.isAllDay
            )
        }

        private static func mapReminder(_ reminder: EKReminder) -> CalendarReminder {
            let dueDate = reminder.dueDateComponents?.date
            return CalendarReminder(
                title: reminder.title ?? "",
                dueDate: dueDate,
                isCompleted: reminder.isCompleted,
                list: reminder.calendar?.title
            )
        }

        /// EventKit's iOS 17+ `requestFullAccessToEvents` is
        /// completion-handler based. Wrapped here so the public
        /// `requestAccess()` can `await` it.
        private func requestFullAccessToEvents() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.store.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if !granted {
                        continuation.resume(throwing: EventKitAccessError.calendarDenied)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        private func requestFullAccessToReminders() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.store.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if !granted {
                        continuation.resume(throwing: EventKitAccessError.remindersDenied)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    // MARK: - EventKitAccessError

    public enum EventKitAccessError: Error, Sendable, Equatable {
        case calendarDenied
        case remindersDenied
    }
#endif
