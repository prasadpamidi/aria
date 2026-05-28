import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - RetryPolicyTests

@Suite("RetryPolicy + WorkflowRetryClassifier")
struct RetryPolicyTests {
    @Test("Fixed backoff returns the configured delay for every attempt > 1")
    func fixedBackoff() {
        let policy = RetryPolicy(
            maxAttempts: 3,
            backoff: .fixed(.milliseconds(500))
        )
        #expect(policy.delayBeforeAttempt(1) == nil) // first attempt = no delay
        #expect(policy.delayBeforeAttempt(2) == .milliseconds(500))
        #expect(policy.delayBeforeAttempt(3) == .milliseconds(500))
    }

    @Test("None backoff returns nil even for retries")
    func noneBackoff() {
        let policy = RetryPolicy(maxAttempts: 4, backoff: .none)
        #expect(policy.delayBeforeAttempt(2) == nil)
        #expect(policy.delayBeforeAttempt(4) == nil)
    }

    @Test("Exponential backoff doubles each attempt, capped")
    func exponentialBackoff() {
        let policy = RetryPolicy(
            maxAttempts: 6,
            backoff: .exponential(base: .milliseconds(100), cap: .milliseconds(800))
        )
        #expect(policy.delayBeforeAttempt(1) == nil)
        // attempt 2 → base (100ms)
        #expect(policy.delayBeforeAttempt(2) == .milliseconds(100))
        // attempt 3 → base * 2 (200ms)
        #expect(policy.delayBeforeAttempt(3) == .milliseconds(200))
        // attempt 4 → 400ms
        #expect(policy.delayBeforeAttempt(4) == .milliseconds(400))
        // attempt 5 → 800ms (capped — the unclipped value is 800)
        #expect(policy.delayBeforeAttempt(5) == .milliseconds(800))
        // attempt 6 → cap (1600 unclipped, clamped to 800)
        #expect(policy.delayBeforeAttempt(6) == .milliseconds(800))
    }

    @Test("Default classifier never retries CancellationError — propagation matters")
    func cancellationNeverRetried() {
        let classifier = DefaultWorkflowRetryClassifier()
        #expect(classifier.classify(CancellationError()) == nil)
    }

    @Test("Default classifier categorises WorkflowEngineError.underlying decode failures")
    func underlyingDecodeFailure() {
        let classifier = DefaultWorkflowRetryClassifier()
        let parseError = WorkflowEngineError.underlying(
            "structured-output text did not parse as JSON: malformed"
        )
        #expect(classifier.classify(parseError) == .decodeFailure)
    }

    @Test("Default classifier categorises timeout-tagged underlying errors")
    func underlyingTimeout() {
        let classifier = DefaultWorkflowRetryClassifier()
        let timeout = WorkflowEngineError.underlying("operation timed out")
        #expect(classifier.classify(timeout) == .timeout)
    }

    @Test("Unknown errors return nil (caller treats as 'not retryable')")
    func unknownErrorsNotRetried() {
        struct Surprise: Error { }
        let classifier = DefaultWorkflowRetryClassifier()
        #expect(classifier.classify(Surprise()) == nil)
    }

    @Test("Composed classifier — first match wins, fallback to second")
    func composedClassifierChain() {
        struct StubClassifier: WorkflowRetryClassifier {
            let result: RetryPolicy.RetryableError?
            func classify(_: any Error) -> RetryPolicy.RetryableError? { result }
        }
        let base = DefaultWorkflowRetryClassifier()
        let chained = base.compose(StubClassifier(result: .rateLimited))
        // Default doesn't match a surprise; chained falls through to stub.
        struct Surprise: Error { }
        #expect(chained.classify(Surprise()) == .rateLimited)
        // Default DOES match a decode failure; stub never sees it.
        let parseError = WorkflowEngineError.underlying("text did not parse as JSON: x")
        #expect(chained.classify(parseError) == .decodeFailure)
    }

    @Test("RetryPolicy is Codable — survives workflow persistence round-trip")
    func policyRoundTripsThroughCodable() throws {
        let policy = RetryPolicy(
            maxAttempts: 3,
            backoff: .exponential(base: .milliseconds(250), cap: .seconds(5)),
            retryOn: [.decodeFailure, .rateLimited]
        )
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(RetryPolicy.self, from: data)
        #expect(decoded == policy)
    }
}
