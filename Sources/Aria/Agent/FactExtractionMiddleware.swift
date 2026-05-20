import Foundation

// MARK: - FactExtractionMiddleware

/// After each turn, scans the latest user message for durable facts
/// and proposes each one to a `MemoryGate` for persistence.
///
/// **Two-stage architecture.** This middleware owns *message-level
/// decomposition*: it asks an extractor LLM to turn one user
/// message into a list of candidate fact strings. It does **not**
/// own validation, dedup, or the write itself — those are the
/// `MemoryGate`'s job. Routing through a gate means this auto path
/// and the `RememberTool` proposal path share one policy: the
/// validator inside the gate decides what counts as a durable user
/// fact, the gate dedupes against existing memory, and the gate
/// stamps `source` metadata.
///
/// **Cost.** One extractor call per user turn, plus one validator
/// call per candidate fact inside the gate. Both are typically
/// cheap (auxiliary LLMs); the gate's validator dominates the
/// pipeline-correctness end of things.
///
/// **Graceful degradation.** Extractor errors are swallowed; gate
/// rejections are not retried; gate write failures are swallowed.
/// The agent's reply has already been delivered — failing this
/// observational pass would be user-visible while gaining nothing.
///
/// **Ordering.** Wire after the agent loop completes (which is what
/// `afterStep` is for). Position in the middleware chain doesn't
/// matter much; can go last.
public struct FactExtractionMiddleware: AgentMiddleware {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - gate: Sole authority for memory writes. The middleware
    ///     proposes candidate facts; the gate validates, dedupes,
    ///     and persists.
    ///   - extractor: Async function the middleware calls with the
    ///     latest user message, returns a list of candidate fact
    ///     strings. An empty list means "nothing worth saving from
    ///     this turn." The extractor is *separate* from the gate's
    ///     validator — extractor does message decomposition, gate
    ///     does per-fact validation.
    ///   - extraMetadata: Optional caller-provided metadata merged
    ///     into each accepted memory (e.g. `["thread_id": …]` for
    ///     audit). The gate adds `source = "auto_extracted"`
    ///     automatically; callers don't need to set it.
    public init(
        gate: any MemoryGate,
        extractor: @escaping @Sendable (Message) async throws -> [String],
        extraMetadata: @escaping @Sendable (AgentState) -> [String: JSONValue] = { _ in [:] }
    ) {
        self.gate = gate
        self.extractor = extractor
        self.extraMetadata = extraMetadata
    }

    // MARK: Public

    public func afterStep(_ state: AgentState) async throws -> AgentState {
        // Only inspect user turns. afterStep often fires with the
        // assistant's reply as the latest message — skip those.
        guard let latest = state.messages.last, latest.role == .user else {
            return state
        }

        let facts: [String]
        do {
            facts = try await self.extractor(latest)
        } catch {
            // Fail-open at the extraction stage: extractor failure
            // shouldn't break the user-visible turn.
            return state
        }

        guard !facts.isEmpty else {
            return state
        }

        let metadata = self.extraMetadata(state)
        for fact in facts {
            do {
                _ = try await self.gate.propose(
                    fact: fact,
                    source: .autoExtracted,
                    metadata: metadata
                )
            } catch {
                // Per-fact gate failures are logged at the gate
                // level; skip the rest of the batch only if the
                // failure is fatal (it's not — propose throws only
                // for unrecoverable store errors and even then we
                // want to try the next fact).
                continue
            }
        }

        return state
    }

    // MARK: Private

    private let gate: any MemoryGate
    private let extractor: @Sendable (Message) async throws -> [String]
    private let extraMetadata: @Sendable (AgentState) -> [String: JSONValue]
}
