import Foundation

// MARK: - AttemptOutcome

/// What one tier produced, judged after the fact.
///
/// Escalation is decided from a completed attempt rather than from a
/// prediction about the incoming request. Predicting "is this turn hard
/// enough to need a bigger model?" is roughly as hard as the turn
/// itself, and the component available to make that prediction cheaply
/// is the small model we already don't trust. Observing that an attempt
/// produced nothing, threw, or named a tool that doesn't exist requires
/// no judgement at all.
public struct AttemptOutcome: Sendable {
    // MARK: Lifecycle

    public init(
        text: String,
        toolCalls: [ToolCall],
        knownToolNames: Set<String>,
        finishReason: FinishReason?,
        error: (any Error)?,
        emittedVisibleOutput: Bool,
        tierIndex: Int
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.knownToolNames = knownToolNames
        self.finishReason = finishReason
        self.error = error
        self.emittedVisibleOutput = emittedVisibleOutput
        self.tierIndex = tierIndex
    }

    // MARK: Public

    /// Everything the attempt produced as visible text.
    public let text: String

    /// Tool calls the attempt requested or executed.
    public let toolCalls: [ToolCall]

    /// Tools that were actually offered, so a policy can spot a call
    /// naming something that was never registered.
    public let knownToolNames: Set<String>

    public let finishReason: FinishReason?
    public let error: (any Error)?

    /// `true` once any non-whitespace text reached the consumer.
    ///
    /// When this is `true` the attempt is already on screen and can no
    /// longer be retried — see `TieredLLMProvider` for why the window
    /// closes here.
    public let emittedVisibleOutput: Bool

    /// Position of the tier that produced this, counting from zero.
    public let tierIndex: Int

    /// `true` when the attempt produced no usable result of any kind.
    public var isEmpty: Bool {
        self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && self.toolCalls.isEmpty
    }

    /// Tool calls naming something that was never offered.
    public var unknownToolCalls: [ToolCall] {
        self.toolCalls.filter { !self.knownToolNames.contains($0.name) }
    }
}

// MARK: - EscalationPolicy

/// Decides whether a completed attempt should be retried on a stronger
/// tier.
public protocol EscalationPolicy: Sendable {
    func shouldEscalate(_ outcome: AttemptOutcome) -> Bool
}

// MARK: - DefaultEscalationPolicy

/// Escalates only on unambiguous failure.
///
/// Deliberately conservative. Every trigger here is a fact about the
/// attempt, not an opinion about its quality — a policy that tried to
/// judge whether an answer was *good* would need a model to do it, and
/// would escalate on taste rather than on failure.
public struct DefaultEscalationPolicy: EscalationPolicy {
    // MARK: Lifecycle

    public init(
        escalateOnError: Bool = true,
        escalateOnEmpty: Bool = true,
        escalateOnUnknownTool: Bool = true
    ) {
        self.escalateOnError = escalateOnError
        self.escalateOnEmpty = escalateOnEmpty
        self.escalateOnUnknownTool = escalateOnUnknownTool
    }

    // MARK: Public

    public func shouldEscalate(_ outcome: AttemptOutcome) -> Bool {
        // An attempt already on screen cannot be retracted, whatever
        // else is wrong with it.
        guard !outcome.emittedVisibleOutput else {
            return false
        }
        if self.escalateOnError, outcome.error != nil {
            return true
        }
        if self.escalateOnEmpty, outcome.isEmpty {
            return true
        }
        // Small models hallucinate tool names readily. The call cannot
        // be dispatched, so the turn is lost either way — retrying it
        // on a stronger tier costs only latency.
        if self.escalateOnUnknownTool, !outcome.unknownToolCalls.isEmpty {
            return true
        }
        return false
    }

    // MARK: Private

    private let escalateOnError: Bool
    private let escalateOnEmpty: Bool
    private let escalateOnUnknownTool: Bool
}

// MARK: - TieredLLMProvider

/// Runs the cheapest capable model first and retries upward on failure.
///
/// A decorator, so `Agent`, `AgentStep`, and every existing consumer
/// need no changes — it is simply an `LLMProvider` that happens to have
/// several inside it.
///
/// **Capabilities are the intersection across tiers, not tier 0's.**
/// A request is assembled once and may be sent to any tier, so it must
/// be valid for all of them: the smallest context window, and only the
/// features every tier supports.
///
/// An earlier version reported tier 0's, reasoning that a context
/// fitting a small model always fits a larger one. That is false.
/// Ladders are ordered by *capability*, and capability does not imply
/// context length — Apple's on-device model is stronger than a 1.2B at
/// instruction-following while offering a 4,096-token window against
/// that model's 6,144. Escalating upward moved downward in context, and
/// requests budgeted for tier 0 were refused by tier 1 with
/// `exceededContextWindowSize`.
///
/// **The streaming boundary.** Judging an attempt needs its outcome;
/// feeling responsive needs streaming. Events are therefore buffered
/// until either non-whitespace text appears — at which point everything
/// flushes and the tier is committed to irrevocably — or the attempt
/// ends having shown nothing, in which case the policy may retry with
/// nothing to retract.
///
/// That boundary is more useful than it first appears, because the
/// failures worth escalating on fall inside it: a provider that threw,
/// an empty completion, and — most importantly — tool-call-only turns,
/// which emit no visible text by construction and so stay inspectable
/// for their entire duration. Tool calling is where small models fail
/// hardest, and it is precisely where escalation is free.
///
/// Known limit: degenerate repetition begins *after* the first token
/// and so falls outside the window. Catching it would require aborting
/// mid-stream and having the consumer discard partial output.
public struct TieredLLMProvider: LLMProvider {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - tiers: Providers ordered cheapest first. An empty array is
    ///     rejected; a single entry behaves exactly like that provider.
    ///   - policy: Decides retries. Defaults to unambiguous failures.
    ///   - validateBeforeYield: Buffer the whole attempt before
    ///     emitting anything, so the policy sees complete output even
    ///     when the attempt produced visible text.
    ///
    ///     For work with no UI attached — structured extraction, a
    ///     classification step — there is no partial output to protect,
    ///     so the streaming boundary buys nothing and full validation
    ///     is strictly better. Leave it off for visible chat, where it
    ///     would trade away first-token latency, which is most of the
    ///     perceived speed of an on-device model.
    ///   - onEscalation: Notified when a tier is abandoned. Escalation
    ///     rate is a diagnostic in its own right: a tier 0 that
    ///     escalates on most turns is the wrong default model, and
    ///     silently paying double latency hides that rather than
    ///     fixing it.
    public init(
        tiers: [any LLMProvider],
        policy: any EscalationPolicy = DefaultEscalationPolicy(),
        validateBeforeYield: Bool = false,
        onEscalation: (@Sendable (AttemptOutcome) -> Void)? = nil
    ) {
        precondition(!tiers.isEmpty, "TieredLLMProvider requires at least one tier")
        self.tiers = tiers
        self.policy = policy
        self.validateBeforeYield = validateBeforeYield
        self.onEscalation = onEscalation
    }

    // MARK: Public

    /// The conservative intersection across every tier.
    ///
    /// A request is assembled once and may be sent to any tier, so it
    /// has to be valid for all of them: the smallest context window,
    /// and only the features every tier supports.
    ///
    /// This corrects an earlier assumption that tier 0's numbers were
    /// sufficient, on the reasoning that a context fitting a small
    /// model always fits a larger one. Escalation ladders are ordered
    /// by *capability*, and capability does not imply context length.
    /// Apple's on-device model is the counterexample that broke it:
    /// stronger than a 1.2B at instruction-following, with a 4,096
    /// window against that model's 6,144. Escalating upward moved
    /// downward in context, and a request budgeted for tier 0 was
    /// refused by tier 1 with `exceededContextWindowSize`.
    public var capabilities: ProviderCapabilities {
        let all = self.tiers.map(\.capabilities)
        // Identity stays the primary's — this is that model, with
        // fallbacks, not a different model.
        let primary = all[0]
        return ProviderCapabilities(
            modelIdentifier: primary.modelIdentifier,
            supportsStreaming: all.allSatisfy(\.supportsStreaming),
            supportsToolUse: all.allSatisfy(\.supportsToolUse),
            supportsParallelToolCalls: all.allSatisfy(\.supportsParallelToolCalls),
            supportsVision: all.allSatisfy(\.supportsVision),
            supportsAudio: all.allSatisfy(\.supportsAudio),
            supportsStructuredOutput: all.allSatisfy(\.supportsStructuredOutput),
            supportsSystemPrompt: all.allSatisfy(\.supportsSystemPrompt),
            maxContextTokens: Self.smallestWindow(all, \.maxContextTokens),
            usableContextTokens: Self.smallestWindow(all, \.usableContextTokens)
        )
    }

    public func stream(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let names = Set(tools.map(\.name))
        return self.runTiers(knownToolNames: names) { tier in
            tier.stream(messages: messages, tools: tools, options: options)
        }
    }

    /// Forwarded so tiers that resolve tools inside their own session —
    /// `FoundationModelsProvider` among them — keep doing so when
    /// wrapped, instead of silently degrading to definition-only
    /// streaming.
    public func stream(
        messages: [Message],
        executableTools: [AnyTool],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let names = Set(executableTools.map(\.name))
        return self.runTiers(knownToolNames: names) { tier in
            tier.stream(messages: messages, executableTools: executableTools, options: options)
        }
    }

    // MARK: Private

    /// Accumulates one attempt while deciding whether it can still be
    /// retried.
    private struct AttemptBuffer {
        var events: [ProviderEvent] = []
        var text = ""
        var toolCalls: [ToolCall] = []
        var finishReason: FinishReason?
        var committed = false

        /// `true` once non-whitespace text has been seen. Whitespace
        /// alone does not close the window — a model that emits a
        /// newline and stops has still shown the user nothing.
        mutating func absorb(_ event: ProviderEvent) -> Bool {
            self.events.append(event)
            switch event {
            case let .textDelta(chunk):
                self.text += chunk
                return !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .toolCallStart(call):
                self.toolCalls.append(call)
            case let .toolCallExecuted(call, _):
                self.toolCalls.append(call)
            case let .messageStop(reason):
                self.finishReason = reason
            default:
                break
            }
            return false
        }
    }

    private let tiers: [any LLMProvider]
    private let policy: any EscalationPolicy
    private let validateBeforeYield: Bool
    private let onEscalation: (@Sendable (AttemptOutcome) -> Void)?

    /// Smallest declared window, ignoring tiers that declare none.
    ///
    /// A tier reporting `nil` is saying "unknown", not "unlimited" —
    /// but it cannot constrain a bound it never stated, so it is
    /// skipped. When no tier declares a window the answer is `nil`,
    /// and the caller falls back to its own conservative default.
    private static func smallestWindow(
        _ capabilities: [ProviderCapabilities],
        _ keyPath: KeyPath<ProviderCapabilities, Int?>
    ) -> Int? {
        capabilities.compactMap { $0[keyPath: keyPath] }.min()
    }

    private func runTiers(
        knownToolNames: Set<String>,
        attempt: @escaping @Sendable (any LLMProvider) -> AsyncThrowingStream<ProviderEvent, any Error>
    ) -> AsyncThrowingStream<ProviderEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.driveTiers(
                    knownToolNames: knownToolNames,
                    attempt: attempt,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Walk the ladder until a tier is accepted or the tiers run out.
    private func driveTiers(
        knownToolNames: Set<String>,
        attempt: @Sendable (any LLMProvider) -> AsyncThrowingStream<ProviderEvent, any Error>,
        continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) async {
        for (index, tier) in self.tiers.enumerated() {
            let (buffer, caught) = await self.runAttempt(
                on: tier,
                attempt: attempt,
                continuation: continuation
            )

            // Already on screen: the attempt stands, error and all.
            // Retrying now would retract text the user has read.
            if buffer.committed {
                continuation.finish(throwing: caught)
                return
            }

            let outcome = AttemptOutcome(
                text: buffer.text,
                toolCalls: buffer.toolCalls,
                knownToolNames: knownToolNames,
                finishReason: buffer.finishReason,
                error: caught,
                emittedVisibleOutput: false,
                tierIndex: index
            )

            let isLastTier = index == self.tiers.count - 1
            if !isLastTier, self.policy.shouldEscalate(outcome) {
                self.onEscalation?(outcome)
                continue
            }

            // Accepted, or nothing better to try: release what was
            // held back.
            for buffered in buffer.events {
                continuation.yield(buffered)
            }
            continuation.finish(throwing: caught)
            return
        }
        continuation.finish()
    }

    /// Consume one tier's stream, holding events back until the tier is
    /// committed to.
    private func runAttempt(
        on tier: any LLMProvider,
        attempt: @Sendable (any LLMProvider) -> AsyncThrowingStream<ProviderEvent, any Error>,
        continuation: AsyncThrowingStream<ProviderEvent, any Error>.Continuation
    ) async -> (AttemptBuffer, (any Error)?) {
        var buffer = AttemptBuffer()
        do {
            for try await event in attempt(tier) {
                let becameVisible = buffer.absorb(event)
                if buffer.committed {
                    continuation.yield(event)
                    continue
                }
                // Committing on first visible text keeps streaming
                // intact; everything buffered so far flushes in order.
                if becameVisible, !self.validateBeforeYield {
                    buffer.committed = true
                    for buffered in buffer.events {
                        continuation.yield(buffered)
                    }
                }
            }
        } catch {
            return (buffer, error)
        }
        return (buffer, nil)
    }
}
