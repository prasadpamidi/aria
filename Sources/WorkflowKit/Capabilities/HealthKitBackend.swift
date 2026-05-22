#if canImport(HealthKit)
    import Foundation
    import HealthKit

    // MARK: - HealthKitBackend

    /// Production HealthKit-backed implementation. Wraps a single
    /// `HKHealthStore` per Apple's guidance.
    ///
    /// Read-only — the P0 capability never writes samples back.
    /// Write capability (e.g. logging water from a workflow)
    /// belongs in a separate slice with its own authorization
    /// flow because the HealthKit consent sheet distinguishes
    /// read and write categories.
    public final class HealthKitBackend: HealthBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init(store: HKHealthStore = HKHealthStore()) {
            self.store = store
        }

        // MARK: Public

        // MARK: HealthBackend

        public func requestAccess() async throws {
            guard HKHealthStore.isHealthDataAvailable() else {
                throw HealthKitAccessError.unavailableOnDevice
            }
            try await self.store.requestAuthorization(
                toShare: [],
                read: Self.readTypes
            )
        }

        public func dailySteps(days: Int) async throws -> [DailyStepBucket] {
            guard let type = HKSampleType.quantityType(forIdentifier: .stepCount) else {
                return []
            }
            let calendar = Calendar.current
            let now = Date()
            let startOfToday = calendar.startOfDay(for: now)
            guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) else {
                return []
            }
            let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: now)
            let interval = DateComponents(day: 1)

            return try await withCheckedThrowingContinuation { continuation in
                let query = HKStatisticsCollectionQuery(
                    quantityType: type,
                    quantitySamplePredicate: predicate,
                    options: [.cumulativeSum],
                    anchorDate: windowStart,
                    intervalComponents: interval
                )
                query.initialResultsHandler = { _, results, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    var output: [DailyStepBucket] = []
                    results?.enumerateStatistics(from: windowStart, to: now) { stats, _ in
                        let value = stats.sumQuantity()?.doubleValue(for: .count()) ?? 0
                        output.append(DailyStepBucket(start: stats.startDate, steps: Int(value)))
                    }
                    continuation.resume(returning: output)
                }
                self.store.execute(query)
            }
        }

        public func lastSleep() async throws -> SleepSession? {
            guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
                return nil
            }
            let sample: HKCategorySample? = try await Self.firstSample(
                store: self.store,
                type: type
            ) as? HKCategorySample
            guard let sample else {
                return nil
            }
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0
            return SleepSession(
                start: sample.startDate,
                end: sample.endDate,
                asleepMinutes: minutes
            )
        }

        public func lastWorkout() async throws -> WorkoutSummary? {
            let workout: HKWorkout? = try await Self.firstSample(
                store: self.store,
                type: HKObjectType.workoutType()
            ) as? HKWorkout
            guard let workout else {
                return nil
            }
            return WorkoutSummary(
                type: Self.workoutTypeName(workout.workoutActivityType),
                start: workout.startDate,
                end: workout.endDate,
                durationMinutes: workout.duration / 60.0,
                activeKilocalories: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            )
        }

        public func waterToday() async throws -> Double {
            guard let type = HKSampleType.quantityType(forIdentifier: .dietaryWater) else {
                return 0
            }
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: Date())
            // Use `Date()` post-startOfDay so `end > start` even
            // if the user invokes at exact midnight (which the
            // sim sometimes does). `.strictStartDate` makes the
            // predicate count only samples whose START falls in
            // the day — without it iOS 17+ HKStatisticsQuery
            // rejects the predicate as invalid for cumulative
            // aggregation in some authorization states. That's
            // the "predicate issue" the run sheet surfaced as
            // an opaque HKError.
            let end = max(Date(), start.addingTimeInterval(1))
            let predicate = HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: .strictStartDate
            )
            return try await withCheckedThrowingContinuation { continuation in
                let query = HKStatisticsQuery(
                    quantityType: type,
                    quantitySamplePredicate: predicate,
                    options: .cumulativeSum
                ) { _, stats, error in
                    if let error = error as NSError? {
                        // "No data available for the specified
                        // predicate" (HKError.errorNoData = 11)
                        // isn't a failure — it means the user
                        // simply hasn't logged any water samples
                        // for today. Return 0 mL so workflows
                        // can branch on `b.water.milliliters > N`
                        // instead of treating zero-intake as
                        // an exception.
                        if error.domain == HKErrorDomain,
                           error.code == HKError.Code.errorNoData.rawValue {
                            continuation.resume(returning: 0)
                            return
                        }
                        // Other errors stay surfaced — wrap so
                        // the workflow run sheet shows a
                        // human-readable message rather than
                        // `Error Domain=… Code=…`.
                        continuation.resume(throwing: HealthKitAccessError.queryFailed(
                            "Water query failed: \(error.localizedDescription)"
                        ))
                        return
                    }
                    let value = stats?
                        .sumQuantity()?
                        .doubleValue(for: .literUnit(with: .milli)) ?? 0
                    continuation.resume(returning: value)
                }
                self.store.execute(query)
            }
        }

        // MARK: Private

        private static let readTypes: Set<HKObjectType> = {
            var set: Set<HKObjectType> = [HKObjectType.workoutType()]
            if let steps = HKSampleType.quantityType(forIdentifier: .stepCount) {
                set.insert(steps)
            }
            if let water = HKSampleType.quantityType(forIdentifier: .dietaryWater) {
                set.insert(water)
            }
            if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                set.insert(sleep)
            }
            return set
        }()

        private let store: HKHealthStore

        /// Generic "give me the single most-recent sample of this
        /// type" — used for sleep + workout.
        private static func firstSample(
            store: HKHealthStore,
            type: HKSampleType
        ) async throws -> HKSample? {
            try await withCheckedThrowingContinuation { continuation in
                let descriptor = NSSortDescriptor(
                    key: HKSampleSortIdentifierEndDate,
                    ascending: false
                )
                let query = HKSampleQuery(
                    sampleType: type,
                    predicate: nil,
                    limit: 1,
                    sortDescriptors: [descriptor]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples?.first)
                    }
                }
                store.execute(query)
            }
        }

        /// Stable human-readable label per workout type. Kept
        /// narrow on purpose — the four most common workout
        /// types cover most users; everything else falls into
        /// `"Other"` rather than dumping the raw rawValue.
        private static func workoutTypeName(_ activity: HKWorkoutActivityType) -> String {
            switch activity {
            case .running: "Running"
            case .walking: "Walking"
            case .cycling: "Cycling"
            case .functionalStrengthTraining, .traditionalStrengthTraining: "Strength"
            case .yoga: "Yoga"
            case .swimming: "Swimming"
            case .highIntensityIntervalTraining: "HIIT"
            default: "Other"
            }
        }
    }

    // MARK: - HealthKitAccessError

    public enum HealthKitAccessError: LocalizedError, Sendable, Equatable {
        case unavailableOnDevice
        /// A HealthKit query rejected its predicate or returned
        /// an unexpected error. The associated string is the
        /// underlying HKError's localizedDescription with the
        /// caller's context prepended so the workflow run sheet
        /// can show something readable.
        case queryFailed(String)

        // MARK: Public

        public var errorDescription: String? {
            switch self {
            case .unavailableOnDevice:
                "HealthKit isn't available on this device."
            case let .queryFailed(message):
                message
            }
        }
    }
#endif
