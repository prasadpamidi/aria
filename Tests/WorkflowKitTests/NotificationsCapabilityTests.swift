import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - NotificationsCapabilityTests

/// Coverage for the `UNUserNotificationCenter`-backed capability
/// using `InMemoryNotificationsBackend`. Real notification
/// scheduling needs iOS permission + a running notification
/// center; this suite owns the capability's arg parsing +
/// dispatch + auth lifecycle.
struct NotificationsCapabilityTests {
    // MARK: Internal

    @Test
    func scheduleRecordsPendingNotification() async throws {
        let backend = InMemoryNotificationsBackend()
        let capability = NotificationsCapability(backend: backend)
        let fireAt = Date().addingTimeInterval(3600)
        let formatter = Self.iso8601Formatter()

        let result = try await capability.call(
            method: "schedule",
            arguments: [
                "title": .string("Hydration check"),
                "body": .string("Drink some water"),
                "fireAt": .string(formatter.string(from: fireAt)),
                "identifier": .string("hydration-1"),
            ],
            context: Self.context()
        )

        #expect(result == .object(["identifier": .string("hydration-1")]))
        let pending = await backend.pendingNotifications()
        #expect(pending.count == 1)
        #expect(pending.first?.title == "Hydration check")
        #expect(pending.first?.identifier == "hydration-1")
    }

    @Test
    func scheduleAcceptsNaiveDatetimeAsLocalTime() async throws {
        // Small LLMs routinely emit `fireAt` as a naïve
        // datetime — no `Z`, no offset — when scheduling
        // a notification from an "at 6pm" intent. The
        // permissive parser must resolve those in the user's
        // local timezone so the alert fires at the wall-clock
        // time the user actually meant. Regression test for
        // the bug where strict ISO parsing rejected the
        // naïve shape, forcing the model to emit `Z` and
        // accidentally schedule in UTC.
        let backend = InMemoryNotificationsBackend()
        let capability = NotificationsCapability(backend: backend)

        // Build a naïve datetime ~1 hour from now, in local time.
        let target = Date().addingTimeInterval(3600)
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone.current
        naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let naiveString = naive.string(from: target)
        // Sanity-check the shape — must NOT end in Z and
        // must NOT contain a timezone offset.
        #expect(!naiveString.hasSuffix("Z"))
        #expect(!naiveString.contains("+"))

        _ = try await capability.call(
            method: "schedule",
            arguments: [
                "title": .string("Local naïve"),
                "body": .string("should fire at local 6pm not UTC 6pm"),
                "fireAt": .string(naiveString),
                "identifier": .string("naive-local"),
            ],
            context: Self.context()
        )

        let pending = await backend.pendingNotifications()
        #expect(pending.count == 1)
        if let first = pending.first {
            // Must resolve within a couple seconds of the
            // intended target (truncation of sub-second
            // fractions accounts for the tiny slack).
            let delta = abs(first.fireAt.timeIntervalSince(target))
            #expect(delta < 2.0)
        }
    }

    @Test
    func scheduleRejectsPastFireAt() async throws {
        let backend = InMemoryNotificationsBackend()
        let capability = NotificationsCapability(backend: backend)
        let past = Date().addingTimeInterval(-3600)
        let formatter = Self.iso8601Formatter()
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "schedule",
                arguments: [
                    "title": .string("late"),
                    "body": .string("too late"),
                    "fireAt": .string(formatter.string(from: past)),
                ],
                context: Self.context()
            )
        }
    }

    @Test
    func scheduleInComputesFireTimeFromOffset() async throws {
        let backend = InMemoryNotificationsBackend()
        let capability = NotificationsCapability(backend: backend)
        let before = Date()
        _ = try await capability.call(
            method: "scheduleIn",
            arguments: [
                "title": .string("Stand up"),
                "body": .string("Time to move"),
                "secondsFromNow": .integer(60),
            ],
            context: Self.context()
        )
        let pending = await backend.pendingNotifications()
        #expect(pending.count == 1)
        if let first = pending.first {
            let delta = first.fireAt.timeIntervalSince(before)
            #expect(delta >= 60 && delta < 62)
        }
    }

    @Test
    func cancelDropsPendingNotification() async throws {
        let backend = InMemoryNotificationsBackend()
        let capability = NotificationsCapability(backend: backend)
        let formatter = Self.iso8601Formatter()
        let fireAt = Date().addingTimeInterval(3600)
        _ = try await capability.call(
            method: "schedule",
            arguments: [
                "title": .string("X"),
                "body": .string("Y"),
                "fireAt": .string(formatter.string(from: fireAt)),
                "identifier": .string("doomed"),
            ],
            context: Self.context()
        )
        let result = try await capability.call(
            method: "cancel",
            arguments: ["identifier": .string("doomed")],
            context: Self.context()
        )
        #expect(result == .object(["ok": .bool(true)]))
        let pending = await backend.pendingNotifications()
        #expect(pending.isEmpty)
    }

    @Test
    func scheduleWithDuplicateIdentifierReplacesPrior() async throws {
        // iOS semantics: re-using an identifier overwrites the
        // prior pending notification. Verify the capability
        // surfaces that behaviour rather than appending.
        let backend = InMemoryNotificationsBackend()
        let capability = NotificationsCapability(backend: backend)
        let formatter = Self.iso8601Formatter()
        let fireAt = Date().addingTimeInterval(3600)
        for body in ["first", "second"] {
            _ = try await capability.call(
                method: "schedule",
                arguments: [
                    "title": .string("T"),
                    "body": .string(body),
                    "fireAt": .string(formatter.string(from: fireAt)),
                    "identifier": .string("same-id"),
                ],
                context: Self.context()
            )
        }
        let pending = await backend.pendingNotifications()
        #expect(pending.count == 1)
        #expect(pending.first?.body == "second")
    }

    @Test
    func authorizationDenialSurfacesAsUnavailable() async throws {
        let backend = InMemoryNotificationsBackend(authorizationGranted: false)
        let capability = NotificationsCapability(backend: backend)
        let formatter = Self.iso8601Formatter()
        let fireAt = Date().addingTimeInterval(3600)
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "schedule",
                arguments: [
                    "title": .string("nope"),
                    "body": .string("denied"),
                    "fireAt": .string(formatter.string(from: fireAt)),
                ],
                context: Self.context()
            )
        }
    }

    @Test
    func pendingReportsScheduledIdentifiers() async throws {
        let backend = InMemoryNotificationsBackend()
        let capability = NotificationsCapability(backend: backend)
        let formatter = Self.iso8601Formatter()
        let fireAt = Date().addingTimeInterval(3600)
        for id in ["a", "b", "c"] {
            _ = try await capability.call(
                method: "schedule",
                arguments: [
                    "title": .string(id),
                    "body": .string(id),
                    "fireAt": .string(formatter.string(from: fireAt)),
                    "identifier": .string(id),
                ],
                context: Self.context()
            )
        }
        let result = try await capability.call(
            method: "pending",
            arguments: [:],
            context: Self.context()
        )
        guard case let .object(dict) = result, case let .array(ids) = dict["identifiers"] ?? .null else {
            Issue.record("Expected { identifiers: [...] }")
            return
        }
        let strings = ids.compactMap { value -> String? in
            if case let .string(s) = value {
                return s
            }
            return nil
        }
        #expect(Set(strings) == Set(["a", "b", "c"]))
    }

    // MARK: Private

    private static func iso8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: "sdk.builtin.test",
            callerWorkflowID: nil,
            attended: true
        )
    }
}
