import Aria
import Foundation

// MARK: - HealthCapability

/// HealthKit-backed reader for the four data shapes the Daily
/// Brief + Health Weekly Review templates lean on: step counts,
/// most-recent sleep, most-recent workout, today's water intake.
///
/// Read-only in P0. Write capability (e.g. logging water from a
/// workflow) belongs in a separate slice with its own
/// authorization request — HealthKit's consent sheet
/// distinguishes read and write categories, so the user has to
/// opt in explicitly per direction.
public actor HealthCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any HealthBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .health
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
        case "recentSteps":
            return try await self.handleRecentSteps(arguments: arguments)
        case "lastSleep":
            return try await self.handleLastSleep()
        case "lastWorkout":
            return try await self.handleLastWorkout()
        case "waterToday":
            return try await self.handleWaterToday()
        default:
            throw CapabilityError.unknownMethod(capability: .health, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = [
        "recentSteps",
        "lastSleep",
        "lastWorkout",
        "waterToday",
    ]

    static let defaultStepDays = 7
    static let maxStepDays = 90

    // MARK: Private

    private static nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let backend: any HealthBackend
    private var didRequestAccess = false

    private static func encodeStepBucket(_ bucket: DailyStepBucket) -> JSONValue {
        .object([
            "start": .string(self.iso8601Formatter.string(from: bucket.start)),
            "steps": .integer(Int64(bucket.steps)),
        ])
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

    private func handleRecentSteps(arguments: [String: JSONValue]) async throws -> JSONValue {
        let requested = Self.optionalIntArg("days", from: arguments) ?? Self.defaultStepDays
        let days = max(1, min(requested, Self.maxStepDays))
        let buckets = try await self.backend.dailySteps(days: days)
        return .array(buckets.map(Self.encodeStepBucket))
    }

    private func handleLastSleep() async throws -> JSONValue {
        guard let sleep = try await self.backend.lastSleep() else {
            return .null
        }
        return .object([
            "start": .string(Self.iso8601Formatter.string(from: sleep.start)),
            "end": .string(Self.iso8601Formatter.string(from: sleep.end)),
            "asleepMinutes": .number(sleep.asleepMinutes),
        ])
    }

    private func handleLastWorkout() async throws -> JSONValue {
        guard let workout = try await self.backend.lastWorkout() else {
            return .null
        }
        var object: [String: JSONValue] = [
            "type": .string(workout.type),
            "start": .string(Self.iso8601Formatter.string(from: workout.start)),
            "end": .string(Self.iso8601Formatter.string(from: workout.end)),
            "durationMinutes": .number(workout.durationMinutes),
        ]
        if let calories = workout.activeKilocalories {
            object["activeKilocalories"] = .number(calories)
        }
        return .object(object)
    }

    private func handleWaterToday() async throws -> JSONValue {
        let milliliters = try await self.backend.waterToday()
        return .object([
            "milliliters": .number(milliliters),
        ])
    }
}
