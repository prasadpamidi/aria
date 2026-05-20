import Foundation

// MARK: - MemorySource

/// Where a memory proposal came from. Tagged onto every accepted
/// write as `metadata["source"]` so audit / retention / display
/// rules can differentiate model-fired tool calls from
/// system-driven automatic extraction from explicit user actions.
public enum MemorySource: String, Sendable, Codable {
    /// The model invoked a "remember" tool. Treat as a *proposal*;
    /// the gate validates whether the proposed fact is actually
    /// durable user knowledge before persisting.
    case toolCall = "tool_call"

    /// An auxiliary extraction pass over the user's message
    /// produced this fact. Source LLM is typically more reliable
    /// than whichever model is running the chat, but the gate
    /// still applies dedup + normalization.
    case autoExtracted = "auto_extracted"

    /// A user-driven action wrote this memory directly (e.g. a
    /// Settings "remember this" entry). No model involvement.
    case explicit
}

// MARK: - MemoryGateDecision

/// Outcome of a memory proposal. Three states, matching the
/// information a caller needs to give the model (or UI) clear
/// language to acknowledge what happened:
///
///   - `.accepted` — written; the gate may have normalized the
///     content (e.g. rewriting "I'm vegan" → "user is vegan") so
///     the canonical stored form is returned alongside the id.
///   - `.duplicate` — a sibling memory already encodes the same
///     fact at high similarity. Existing id + content are
///     returned so callers can reference it.
///   - `.rejected` — the proposal didn't survive validation. The
///     reason is short, user/model-facing prose ("Not a durable
///     user fact").
public enum MemoryGateDecision: Sendable, Equatable {
    case accepted(memoryId: String, normalizedContent: String)
    case duplicate(existingId: String, existingContent: String)
    case rejected(reason: String)
}

// MARK: - MemoryGate

/// Single authority for memory writes. Every code path that wants
/// to remember something — a `remember_fact` tool call, the
/// post-turn fact extractor, a user-driven "save this" action —
/// routes through `propose(fact:source:metadata:)`. The gate owns:
///
///   1. **Validation / normalization.** Decide whether the proposed
///      string is actually a durable user fact and, if so, rewrite
///      it into a canonical form. Implementations typically delegate
///      this to a small reliable LLM (e.g. Apple FoundationModels)
///      regardless of which chat model fired the proposal — so a
///      weak chat model can't poison the store by proposing world
///      knowledge as "user facts."
///   2. **Dedup.** Reject proposals that already exist in the store
///      at high embedding similarity. Saves the model from a
///      "saved Prasad already, save it again" loop.
///   3. **Write + metadata tagging.** Stamp `source` and any
///      caller-provided metadata onto the stored item.
///
/// Concentrating these in one type means new memory paths inherit
/// the policy without re-implementing it, and policy evolution
/// (PII scrubbing, conflict resolution, "forget this" rules) lands
/// in one place.
public protocol MemoryGate: Sendable {
    /// Propose a fact for memory persistence. The gate decides
    /// whether to accept (with optional normalization), reject
    /// (with a short reason), or merge into an existing memory.
    func propose(
        fact: String,
        source: MemorySource,
        metadata: [String: JSONValue]
    ) async throws -> MemoryGateDecision
}

// MARK: - ValidatingMemoryGate

/// Default `MemoryGate` implementation: closure-based normalizer +
/// embedding-similarity dedup against a backing `MemoryStore`.
///
/// The `normalize` closure is the policy hook. It receives the raw
/// proposal and the source it came from; it returns either a
/// normalized fact string (accept) or `nil` (reject). Implementing
/// the closure with a reliable auxiliary LLM is what stops a weak
/// chat model from polluting memory with topic chatter — the
/// validator decides, not the chat model.
public final class ValidatingMemoryGate: MemoryGate {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - store: Where accepted memories land.
    ///   - namespace: Memory namespace path (e.g. `["user"]`).
    ///   - dedupThreshold: Cosine-similarity threshold above which a
    ///     proposed fact is treated as a duplicate of an existing
    ///     memory. 0.85 matches the prior in-tool dedup value tuned
    ///     against `NLEmbedding`. Passing `nil` disables dedup.
    ///   - normalize: Policy closure. Returns a normalized fact
    ///     string when the proposal is durable user knowledge; `nil`
    ///     when it should be rejected. The rejection reason returned
    ///     by `propose` defaults to a generic message — supply the
    ///     `rejectionReason` parameter to override.
    ///   - rejectionReason: Short prose the gate returns to callers
    ///     when `normalize` declines a proposal. Defaults to a
    ///     model-friendly phrasing that closes the loop without
    ///     inviting a retry.
    public init(
        store: any MemoryStore,
        namespace: [String],
        dedupThreshold: Float? = 0.85,
        normalize: @escaping @Sendable (String, MemorySource) async throws -> String?,
        rejectionReason: String = "Only durable, first-person user facts are remembered."
    ) {
        self.store = store
        self.namespace = namespace
        self.dedupThreshold = dedupThreshold
        self.normalize = normalize
        self.rejectionReason = rejectionReason
    }

    // MARK: Public

    public func propose(
        fact: String,
        source: MemorySource,
        metadata: [String: JSONValue] = [:]
    ) async throws -> MemoryGateDecision {
        let raw = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return .rejected(reason: self.rejectionReason)
        }

        // 1. Validate / normalize. Failure here is fail-closed for
        //    safety — a transient validator outage shouldn't write
        //    unvetted content to long-lived memory. Callers that
        //    want fail-open semantics can wrap the gate themselves.
        let normalized: String
        do {
            guard let result = try await self.normalize(raw, source) else {
                return .rejected(reason: self.rejectionReason)
            }
            normalized = result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return .rejected(reason: self.rejectionReason)
        }
        guard !normalized.isEmpty else {
            return .rejected(reason: self.rejectionReason)
        }

        // 2. Dedup. Compare against the *normalized* form so a
        //    paraphrase doesn't slip past similarity. `topK: 3` is
        //    enough — duplicates dominate by a wide margin.
        if let threshold = self.dedupThreshold {
            let matches = try await self.store.recall(
                query: normalized,
                namespace: self.namespace,
                topK: 3,
                filter: nil
            )
            if let top = matches.first, top.score >= threshold {
                return .duplicate(
                    existingId: top.item.id,
                    existingContent: top.item.content
                )
            }
        }

        // 3. Write with source tag merged into caller metadata.
        var merged = metadata
        merged["source"] = .string(source.rawValue)
        let item = MemoryItem(content: normalized, metadata: merged)
        let ref = try await self.store.remember(item, namespace: self.namespace)
        return .accepted(memoryId: ref.id, normalizedContent: normalized)
    }

    // MARK: Private

    private let store: any MemoryStore
    private let namespace: [String]
    private let dedupThreshold: Float?
    private let normalize: @Sendable (String, MemorySource) async throws -> String?
    private let rejectionReason: String
}
