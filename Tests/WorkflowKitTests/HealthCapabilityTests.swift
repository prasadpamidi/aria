import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - HealthCapabilityTests

/// Coverage for the HealthCapability against
/// `InMemoryHealthBackend` fixtures. Real HealthKit reads only
/// fire on a device; this suite focuses on the encoding +
/// limit-clamping the capability owns.
struct HealthCapabilityTests {
    // MARK: Internal

    // MARK: - recentSteps

    @Test
    func recentStepsEncodesEachDayBucket() async throws {
        let day1 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day1.addingTimeInterval(86400)
        let backend = InMemoryHealthBackend(steps: [
            DailyStepBucket(start: day1, steps: 7350),
            DailyStepBucket(start: day2, steps: 9120),
        ])

        let capability = HealthCapability(backend: backend)
        let result = try await capability.call(
            method: "recentSteps",
            arguments: ["days": .integer(2)],
            context: Self.context()
        )

        guard case let .array(items) = result else {
            Issue.record("Expected array, got \(result)")
            return
        }
        #expect(items.count == 2)
        #expect(items.first == .object([
            "start": .string(Self.iso8601(day1)),
            "steps": .integer(7350),
        ]))
    }

    @Test
    func recentStepsClampsToMaxWindow() async throws {
        let backend = InMemoryHealthBackend(steps: (0..<120).map { index in
            DailyStepBucket(
                start: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index * 86400)),
                steps: index
            )
        })

        let capability = HealthCapability(backend: backend)
        let result = try await capability.call(
            method: "recentSteps",
            arguments: ["days": .integer(10000)],
            context: Self.context()
        )

        guard case let .array(items) = result else {
            Issue.record("Expected array, got \(result)")
            return
        }
        #expect(items.count == HealthCapability.maxStepDays)
    }

    @Test
    func recentStepsDefaultsTo7Days() async throws {
        let backend = InMemoryHealthBackend(steps: (0..<30).map { index in
            DailyStepBucket(
                start: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(index * 86400)),
                steps: index
            )
        })

        let capability = HealthCapability(backend: backend)
        let result = try await capability.call(
            method: "recentSteps",
            arguments: [:],
            context: Self.context()
        )

        guard case let .array(items) = result else {
            Issue.record("Expected array, got \(result)")
            return
        }
        #expect(items.count == HealthCapability.defaultStepDays)
    }

    // MARK: - lastSleep / lastWorkout / waterToday

    @Test
    func lastSleepReturnsNullWhenAbsent() async throws {
        let capability = HealthCapability(backend: InMemoryHealthBackend())
        let result = try await capability.call(
            method: "lastSleep",
            arguments: [:],
            context: Self.context()
        )
        #expect(result == .null)
    }

    @Test
    func lastSleepEncodesAllFields() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 3600)
        let backend = InMemoryHealthBackend(sleep: SleepSession(
            start: start,
            end: end,
            asleepMinutes: 7.5 * 60
        ))

        let capability = HealthCapability(backend: backend)
        let result = try await capability.call(
            method: "lastSleep",
            arguments: [:],
            context: Self.context()
        )

        guard case let .object(dict) = result else {
            Issue.record("Expected object, got \(result)")
            return
        }
        #expect(dict["start"] == .string(Self.iso8601(start)))
        #expect(dict["end"] == .string(Self.iso8601(end)))
        #expect(dict["asleepMinutes"] == .number(450))
    }

    @Test
    func lastWorkoutOmitsCaloriesWhenNil() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(30 * 60)
        let backend = InMemoryHealthBackend(workout: WorkoutSummary(
            type: "Running",
            start: start,
            end: end,
            durationMinutes: 30,
            activeKilocalories: nil
        ))

        let capability = HealthCapability(backend: backend)
        let result = try await capability.call(
            method: "lastWorkout",
            arguments: [:],
            context: Self.context()
        )

        guard case let .object(dict) = result else {
            Issue.record("Expected object, got \(result)")
            return
        }
        #expect(dict["type"] == .string("Running"))
        #expect(dict["durationMinutes"] == .number(30))
        #expect(dict["activeKilocalories"] == nil)
    }

    @Test
    func waterTodayReturnsZeroWhenAbsent() async throws {
        let capability = HealthCapability(backend: InMemoryHealthBackend())
        let result = try await capability.call(
            method: "waterToday",
            arguments: [:],
            context: Self.context()
        )
        #expect(result == .object(["milliliters": .number(0)]))
    }

    @Test
    func waterTodayPassesThroughMilliliters() async throws {
        let capability = HealthCapability(
            backend: InMemoryHealthBackend(waterTodayMilliliters: 1200)
        )
        let result = try await capability.call(
            method: "waterToday",
            arguments: [:],
            context: Self.context()
        )
        #expect(result == .object(["milliliters": .number(1200)]))
    }

    // MARK: - Errors

    @Test
    func unknownMethodThrows() async {
        let capability = HealthCapability(backend: InMemoryHealthBackend())
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
        let capability = HealthCapability(
            backend: InMemoryHealthBackend(authorizationError: DummyError())
        )
        await #expect {
            try await capability.call(
                method: "lastSleep",
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

    private static nonisolated(unsafe) let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Helpers

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: "sdk.builtin.test",
            callerWorkflowID: nil,
            attended: true
        )
    }

    private static func iso8601(_ date: Date) -> String {
        self.iso8601.string(from: date)
    }
}
