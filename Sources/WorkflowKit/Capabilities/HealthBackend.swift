import Foundation

// MARK: - HealthBackend

/// Injection seam for HealthKit. Production
/// `HealthCapability` uses `HealthKitBackend`; tests use
/// `InMemoryHealthBackend` to return canned fixtures without
/// needing HealthKit authorization.
public protocol HealthBackend: Sendable {
    /// Request read access to the data types the capability
    /// reads. Production: triggers the HealthKit auth sheet.
    /// Tests: returns immediately or throws the configured
    /// fixture error.
    func requestAccess() async throws

    /// Daily step counts for the last `days` days, oldest first.
    /// Each entry's `start` is the local day's midnight.
    func dailySteps(days: Int) async throws -> [DailyStepBucket]

    /// The single most-recent sleep session. `nil` when no sleep
    /// has been recorded.
    func lastSleep() async throws -> SleepSession?

    /// The single most-recent workout. `nil` when no workout
    /// has been recorded.
    func lastWorkout() async throws -> WorkoutSummary?

    /// Today's water intake summed across all sources, in
    /// milliliters. Returns 0 when no data is present.
    func waterToday() async throws -> Double
}

// MARK: - DailyStepBucket

public struct DailyStepBucket: Sendable, Equatable {
    // MARK: Lifecycle

    public init(start: Date, steps: Int) {
        self.start = start
        self.steps = steps
    }

    // MARK: Public

    public let start: Date
    public let steps: Int
}

// MARK: - SleepSession

public struct SleepSession: Sendable, Equatable {
    // MARK: Lifecycle

    public init(start: Date, end: Date, asleepMinutes: Double) {
        self.start = start
        self.end = end
        self.asleepMinutes = asleepMinutes
    }

    // MARK: Public

    public let start: Date
    public let end: Date
    /// Total minutes the user was asleep (excluding in-bed time).
    public let asleepMinutes: Double
}

// MARK: - WorkoutSummary

public struct WorkoutSummary: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        type: String,
        start: Date,
        end: Date,
        durationMinutes: Double,
        activeKilocalories: Double?
    ) {
        self.type = type
        self.start = start
        self.end = end
        self.durationMinutes = durationMinutes
        self.activeKilocalories = activeKilocalories
    }

    // MARK: Public

    public let type: String
    public let start: Date
    public let end: Date
    public let durationMinutes: Double
    public let activeKilocalories: Double?
}

// MARK: - InMemoryHealthBackend

public struct InMemoryHealthBackend: HealthBackend {
    // MARK: Lifecycle

    public init(
        steps: [DailyStepBucket] = [],
        sleep: SleepSession? = nil,
        workout: WorkoutSummary? = nil,
        waterTodayMilliliters: Double = 0,
        authorizationError: (any Error)? = nil
    ) {
        self.stepsFixture = steps
        self.sleepFixture = sleep
        self.workoutFixture = workout
        self.waterFixture = waterTodayMilliliters
        self.authorizationError = authorizationError
    }

    // MARK: Public

    // MARK: HealthBackend

    public func requestAccess() async throws {
        if let error = authorizationError {
            throw error
        }
    }

    public func dailySteps(days: Int) async throws -> [DailyStepBucket] {
        // Honor the requested window from the trailing edge of
        // the fixture (most-recent-first then re-sort ascending).
        let trailing = Array(self.stepsFixture.suffix(days))
        return trailing.sorted { $0.start < $1.start }
    }

    public func lastSleep() async throws -> SleepSession? {
        self.sleepFixture
    }

    public func lastWorkout() async throws -> WorkoutSummary? {
        self.workoutFixture
    }

    public func waterToday() async throws -> Double {
        self.waterFixture
    }

    // MARK: Private

    private let stepsFixture: [DailyStepBucket]
    private let sleepFixture: SleepSession?
    private let workoutFixture: WorkoutSummary?
    private let waterFixture: Double
    private let authorizationError: (any Error)?
}
