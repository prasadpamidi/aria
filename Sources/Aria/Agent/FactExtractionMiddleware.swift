import Foundation

// MARK: - FactExtractionMiddleware

/// After each turn, scans the latest user message for durable facts
/// and writes them to a `MemoryStore` so they survive across threads.
///
/// **What this is for.** Today the only way the model accumulates
/// long-term user knowledge is to *explicitly* call a
/// `remember_user_fact` tool mid-turn. That's lossy — the model has
/// to decide a fact is durable, and if it doesn't, the fact dies with
/// the thread. This middleware adds an *automatic* path: every user
/// turn is post-processed by a caller-supplied extractor (typically a
/// cheap LLM) that returns a list of "facts worth remembering."
///
/// **What it preserves.** It runs in `afterStep`, by which point the
/// agent has already produced its reply — the user has seen the
/// response. Extraction is observational: it never modifies state,
/// never delays the next turn (caller can spawn it as a background
/// task if latency matters; the default fire-and-forget shape lets
/// the agent loop continue while extraction runs).
///
/// **Cost.** One extractor call per turn where the latest message is
/// a user message. The extractor is typically a cheap LLM; budget
/// accordingly. The middleware doesn't dedupe — the extractor is
/// expected to either return zero facts ("no new info worth saving")
/// or facts that don't already exist in memory. A `MemoryStore` that
/// supports similarity-based deduplication on `remember` would be a
/// natural place to add that.
///
/// **Graceful degradation.** Extractor errors are swallowed; memory
/// write failures are logged but never thrown. The agent's reply has
/// already been delivered to the user — failing the turn here would
/// be user-visible while gaining nothing.
///
/// **Tagging.** Stored facts carry two metadata fields:
///   - `source = "auto_extracted"` — distinguishes from facts the
///     model explicitly called `remember_user_fact` on. Useful for
///     audit / display rules / different retention policies later.
///   - `thread_id = <the thread the fact came from>` — auditability:
///     a user reviewing remembered facts can trace back to the
///     originating conversation.
///
/// **Ordering.** Wire after the agent loop completes (which is what
/// `afterStep` is for). Position in the middleware chain doesn't
/// matter much; can go last.
public struct FactExtractionMiddleware: AgentMiddleware {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - memory: The store extracted facts get written into.
    ///   - namespace: Per-user namespace (typically `["user"]` or a
    ///     `["user", <userId>]` path).
    ///   - extractor: Async function the middleware calls with the
    ///     latest user message, returns a list of fact strings. An
    ///     empty list means "nothing worth saving from this turn."
    public init(
        memory: any MemoryStore,
        namespace: [String],
        dedupSimilarityThreshold: Float? = 0.9,
        extractor: @escaping @Sendable (Message) async throws -> [String]
    ) {
        self.memory = memory
        self.namespace = namespace
        self.dedupSimilarityThreshold = dedupSimilarityThreshold
        self.extractor = extractor
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
            // Fail-open: extraction failure shouldn't break the turn.
            return state
        }

        guard !facts.isEmpty else {
            return state
        }

        for fact in facts {
            // Dedup: before writing, query the store for similar
            // existing memories. If anything in memory matches above
            // the configured threshold, skip — RAG recall would
            // surface that fact anyway, and a near-dup just clutters
            // the user's memories list. Skipped entirely when the
            // threshold is nil (legacy / opt-out behavior).
            if let threshold = self.dedupSimilarityThreshold,
               try await self.isDuplicate(fact, threshold: threshold) {
                continue
            }

            let metadata: [String: JSONValue] = [
                "source": .string("auto_extracted"),
                "thread_id": .string(state.threadId)
            ]
            do {
                _ = try await self.memory.remember(
                    MemoryItem(content: fact, metadata: metadata),
                    namespace: self.namespace
                )
            } catch {
                // Log-and-swallow: one failed fact write shouldn't
                // skip the rest, and definitely shouldn't fail the
                // user-visible turn.
                continue
            }
        }

        return state
    }

    // MARK: Private

    private let memory: any MemoryStore
    private let namespace: [String]
    private let dedupSimilarityThreshold: Float?
    private let extractor: @Sendable (Message) async throws -> [String]

    /// True when something in memory matches `fact` above the
    /// threshold. A recall failure (e.g. embedder unavailable) treats
    /// the fact as non-duplicate — better to record a near-dup than
    /// silently lose a fact because recall transiently failed.
    private func isDuplicate(_ fact: String, threshold: Float) async throws -> Bool {
        let matches: [MemoryMatch]
        do {
            matches = try await self.memory.recall(
                query: fact,
                namespace: self.namespace,
                topK: 1,
                filter: nil
            )
        } catch {
            return false
        }
        guard let top = matches.first else {
            return false
        }
        return top.score >= threshold
    }
}
