import Foundation

// MARK: - RetryPolicy

/// Per-step retry policy. Eliminates hand-rolled `for attempt in
/// 1...N` loops in every workflow host — the runner handles
/// backoff, classification, and exhaustion. Codable for
/// persistence; Sendable for cross-actor handoff.
///
/// Default-on errors are the ones every small-model deployment
/// sees: structured-decode failures (the model emitted prose despite
/// the schema), timeouts, transient provider failures (rate limits,
/// 5xx, network blips). Hosts pick the right `retryOn` set per
/// workflow — a one-shot transform step shouldn't retry on
/// `decodeFailure`; a 3B-model insights step should.
public struct RetryPolicy: Codable, Sendable, Equatable, Hashable {
    // MARK: Lifecycle

    public init(
        maxAttempts: Int,
        backoff: Backoff = .fixed(.seconds(1)),
        retryOn: Set<RetryableError> = [.decodeFailure, .timeout, .providerTransient]
    ) {
        precondition(maxAttempts >= 1, "maxAttempts must be >= 1")
        self.maxAttempts = maxAttempts
        self.backoff = backoff
        self.retryOn = retryOn
    }

    // MARK: Public

    // MARK: - Backoff

    public enum Backoff: Codable, Sendable, Equatable, Hashable {
        case none
        case fixed(Duration)
        /// `base` doubles each attempt up to `cap`. Apply jitter at
        /// the runner if desired — this struct stays deterministic
        /// so tests can assert exact wait times.
        case exponential(base: Duration, cap: Duration)
    }

    // MARK: - RetryableError

    /// Categories the runner classifies thrown errors into. The
    /// retry policy retries only the categories present in
    /// `retryOn`; anything else propagates immediately.
    ///
    /// Providers map their native error types into these categories
    /// via the `WorkflowRetryClassifier` protocol — the policy itself
    /// stays vendor-neutral.
    public enum RetryableError: String, Codable, Sendable, Hashable, CaseIterable {
        /// Model returned content that failed structured decode
        /// (prose despite schema, malformed JSON, missing required
        /// field). The classic "3B small-model" case.
        case decodeFailure
        /// Per-attempt timeout exceeded.
        case timeout
        /// 5xx, network blip, connection reset, etc.
        case providerTransient
        /// 429 / explicit "too many requests" with a retry-after.
        case rateLimited
    }

    public let maxAttempts: Int
    public let backoff: Backoff
    public let retryOn: Set<RetryableError>

    /// Compute the delay before attempt `n` (1-indexed). Returns
    /// `nil` for the first attempt (no delay) and for
    /// `.none` backoff.
    public func delayBeforeAttempt(_ attempt: Int) -> Duration? {
        guard attempt > 1 else {
            return nil
        }
        switch self.backoff {
        case .none:
            return nil
        case let .fixed(duration):
            return duration
        case let .exponential(base, cap):
            // attempt=2 → base, attempt=3 → 2*base, attempt=4 → 4*base, ...
            // Capped at `cap` so a long retry chain doesn't sleep for ages.
            let factor = 1 << (attempt - 2)
            let scaled = base * factor
            return min(scaled, cap)
        }
    }
}

// MARK: - WorkflowRetryClassifier

/// Provider-supplied bridge that maps thrown errors into
/// `RetryPolicy.RetryableError` categories. The runner consults
/// this before deciding whether the configured `retryOn` set
/// covers the failure.
///
/// Default impl returns `nil` for any error — equivalent to "not
/// retryable" — so a provider that doesn't register a classifier
/// stays on the conservative side rather than retrying anything it
/// shouldn't.
public protocol WorkflowRetryClassifier: Sendable {
    func classify(_ error: any Error) -> RetryPolicy.RetryableError?
}

// MARK: - DefaultWorkflowRetryClassifier

/// Bundled classifier that handles the universal cases:
/// `WorkflowEngineError.underlying` carrying decode-failure text,
/// Swift's `CancellationError` (never retried — propagates), and
/// timeouts originating from `Task.sleep` cancellation. Providers
/// chain their own classifier on top via `compose(_:)` for
/// vendor-specific errors (e.g. OpenAI `RateLimitError`).
public struct DefaultWorkflowRetryClassifier: WorkflowRetryClassifier {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func classify(_ error: any Error) -> RetryPolicy.RetryableError? {
        // Cancellation never retries — let it propagate.
        if error is CancellationError {
            return nil
        }
        // Heuristic on the default `WorkflowEngineError.underlying`
        // string the lenient JSON-parse path throws.
        if let wf = error as? WorkflowEngineError,
           case let .underlying(message) = wf {
            let lowered = message.lowercased()
            if lowered.contains("did not parse") || lowered.contains("not utf-8") {
                return .decodeFailure
            }
            if lowered.contains("timeout") || lowered.contains("timed out") {
                return .timeout
            }
        }
        return nil
    }

    /// Chain a host classifier on top — first match wins. Lets a
    /// host bridge OpenAI / Anthropic / MLX errors without losing
    /// the default coverage.
    public func compose(
        _ next: any WorkflowRetryClassifier
    ) -> any WorkflowRetryClassifier {
        ChainedClassifier(first: self, second: next)
    }
}

// MARK: - ChainedClassifier

private struct ChainedClassifier: WorkflowRetryClassifier {
    let first: any WorkflowRetryClassifier
    let second: any WorkflowRetryClassifier

    func classify(_ error: any Error) -> RetryPolicy.RetryableError? {
        self.first.classify(error) ?? self.second.classify(error)
    }
}
