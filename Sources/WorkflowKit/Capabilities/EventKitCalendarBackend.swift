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

        public func createEvent(
            title: String,
            start: Date,
            end: Date,
            notes: String?,
            calendarName: String?,
            isAllDay: Bool
        ) async throws -> CalendarEvent {
            let event = EKEvent(eventStore: self.store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.notes = notes
            event.isAllDay = isAllDay
            event.calendar = self.eventsCalendar(named: calendarName)
            do {
                try self.store.save(event, span: .thisEvent, commit: true)
            } catch {
                throw EventKitAccessError.writeFailed(String(describing: error))
            }
            return Self.mapEvent(event)
        }

        public func createReminder(
            title: String,
            dueDate: Date?,
            notes: String?,
            listName: String?
        ) async throws -> CalendarReminder {
            let reminder = EKReminder(eventStore: self.store)
            reminder.title = title
            reminder.notes = notes
            reminder.calendar = self.remindersCalendar(named: listName)
            if let dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: dueDate
                )
            }
            do {
                try self.store.save(reminder, commit: true)
            } catch {
                throw EventKitAccessError.writeFailed(String(describing: error))
            }
            return Self.mapReminder(reminder)
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

        /// Resolve which calendar to write a new event into.
        /// `nil` → default events calendar. A named match looks
        /// for a writable calendar whose title equals
        /// `calendarName` (case-insensitive). Falls back to the
        /// default if the name doesn't resolve — better to write
        /// to a known-good calendar than silently drop the event.
        private func eventsCalendar(named calendarName: String?) -> EKCalendar? {
            if let calendarName, !calendarName.isEmpty {
                let match = self.store
                    .calendars(for: .event)
                    .first {
                        $0.allowsContentModifications && $0.title.caseInsensitiveCompare(calendarName) == .orderedSame
                    }
                if let match {
                    return match
                }
            }
            return self.store.defaultCalendarForNewEvents
        }

        private func remindersCalendar(named listName: String?) -> EKCalendar? {
            if let listName, !listName.isEmpty {
                let match = self.store
                    .calendars(for: .reminder)
                    .first { $0.allowsContentModifications && $0.title.caseInsensitiveCompare(listName) == .orderedSame
                    }
                if let match {
                    return match
                }
            }
            return self.store.defaultCalendarForNewReminders()
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

    public enum EventKitAccessError: LocalizedError, Sendable, Equatable {
        case calendarDenied
        case remindersDenied
        case writeFailed(String)

        // MARK: Public

        public var errorDescription: String? {
            switch self {
            case .calendarDenied:
                "The app wasn't granted access to your Calendar."
            case .remindersDenied:
                "The app wasn't granted access to your Reminders."
            case let .writeFailed(detail):
                "Couldn't save to your calendar / reminders: \(detail)"
            }
        }
    }
#endif
