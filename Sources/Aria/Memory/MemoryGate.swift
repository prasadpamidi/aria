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
extension String {
    /// `nil` when there is nothing left after trimming, so a validator
    /// that returns blank falls through to the caller's text.
    fileprivate var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}

// MARK: - ValidatingMemoryGate

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

    /// Shared by every gate that enforces provenance.
    public static let ungroundedReason = """
    Not saved: that fact was not something the user said. Only save \
    facts the user has stated themselves.
    """

    /// Does `fact` share distinctive vocabulary with what the user
    /// wrote?
    ///
    /// Lexical, and measured as a *share* of the proposal rather than
    /// a single hit.
    ///
    /// One shared word is not enough, and the field case shows why: "I
    /// currently practice fasting successfully for 8 days straight"
    /// borrows "fasting" straight from the question "How am I doing
    /// with fasting?" and invents everything else. Overlap of one term
    /// in five reads as grounded under any "shares a word" rule.
    ///
    /// Requiring half the proposal's content to appear in what the user
    /// wrote keeps normalised phrasings — "I'm vegetarian" → "user is
    /// vegetarian" is 1/1, "remember I'm in Berlin" → "user lives in
    /// Berlin" is 1/2 — while that invention scores 0.2.
    ///
    /// The threshold errs strict on purpose. A rejected fact is a fact
    /// the user can simply restate; an accepted fabrication is
    /// permanent, recalled on every subsequent turn, and indistinguishable from something they really said.
    public static func isGrounded(
        _ fact: String,
        in sourceText: String,
        minimumShare: Double = 0.5
    ) -> Bool {
        let factTerms = Self.contentTerms(fact)
        guard !factTerms.isEmpty else {
            return true
        }
        let sourceTerms = Self.contentTerms(sourceText)
        guard !sourceTerms.isEmpty else {
            // Nothing to check against — don't reject on absence of
            // evidence when the caller supplied an empty turn.
            return true
        }
        let shared = factTerms.intersection(sourceTerms).count
        return Double(shared) / Double(factTerms.count) >= minimumShare
    }

    /// Lowercased words of three or more characters, minus the
    /// first-person scaffolding every user fact carries. Without that
    /// subtraction "user is …" matches "I am …" on grammar alone and
    /// the check passes for anything.
    public static func contentTerms(_ text: String) -> Set<String> {
        let scaffolding: Set = [
            "the", "and", "for", "with", "that", "this", "user", "you",
            "your", "are", "was", "were", "has", "have", "had", "his",
            "her", "their", "its", "not", "but", "now", "currently",
            "about", "from", "into", "than", "then", "them", "they",
        ]
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.map(String.init).filter { $0.count >= 3 })
            .subtracting(scaffolding)
    }

    public func propose(
        fact: String,
        source: MemorySource,
        metadata: [String: JSONValue] = [:]
    ) async throws -> MemoryGateDecision {
        let raw = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return .rejected(reason: self.rejectionReason)
        }

        // 0. Provenance. A fact about the user must come from the
        //    user, and a model can invent one that is structurally
        //    perfect.
        //
        //    Observed: asked "How am I doing with fasting?", a model
        //    called `remember_fact` with "I currently practice fasting
        //    successfully for 8 days straight" — never said by anyone —
        //    and it was written to durable memory, recalled on the next
        //    turn, and answered from as fact. Validation cannot catch
        //    that: the sentence is first-person, durable and specific.
        //    It is simply false.
        //
        //    So the check is not "is this a fact?" but "did the user
        //    say it?". Callers pass what the user actually wrote as
        //    `metadata["sourceText"]`; a proposal sharing no
        //    distinctive term with it is a fabrication, whatever it
        //    looks like. Absent that metadata this is skipped, so
        //    existing callers are unaffected.
        if case let .string(sourceText)? = metadata["sourceText"],
           !Self.isGrounded(raw, in: sourceText) {
            return .rejected(reason: Self.ungroundedReason)
        }

        // 0b. A fact the user confirmed does not need the model's
        //     permission.
        //
        //     `normalize` is a policy hook that usually calls a
        //     language model, and it is fail-closed: a validator
        //     outage refuses the write. That is right for a
        //     *model-proposed* fact — unvetted content must not reach
        //     long-lived storage — and wrong for one a person read and
        //     tapped Save on.
        //
        //     Observed: FoundationModels failed mid-turn, the user
        //     confirmed "I live in Dublin, CA", and the write was
        //     refused with "Couldn't save that one." The validator
        //     exists to stop the model writing junk; the user is not
        //     the model, and is the better judge of their own facts.
        //
        //     Dedup still applies below — confirming a fact twice
        //     should still not store it twice.
        let userConfirmed: Bool =
            if case let .bool(flag)? = metadata["confirmed"] {
                flag
            } else {
                false
            }
        if userConfirmed {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .rejected(reason: self.rejectionReason)
            }
            // Skip the validator's *veto*, not its *canonicalisation*.
            //
            // The first version stored confirmed text verbatim, which
            // broke the invariant that every stored fact shares one
            // form: `remember_fact` wrote "I live in Dublin, CA" while
            // extraction wrote "user lives in Dublin, CA". Dedup
            // compares embeddings, and two phrasings of one fact sit
            // far enough apart to be stored twice.
            //
            // So still normalise when the validator can — it is the
            // thing that produces the canonical form — and fall back to
            // the user's own words when it cannot. A confirmed fact is
            // never lost to a validator outage; it just keeps its
            // original phrasing on that one occasion.
            let canonical = await (try? self.normalize(trimmed, source)) ?? nil
            return try await self.store(
                canonical?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? trimmed,
                source: source,
                metadata: metadata
            )
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

        return try await self.store(normalized, source: source, metadata: metadata)
    }

    // MARK: Private

    private let store: any MemoryStore
    private let namespace: [String]
    private let dedupThreshold: Float?
    private let normalize: @Sendable (String, MemorySource) async throws -> String?
    private let rejectionReason: String

    /// Dedup, then write.
    ///
    /// Shared by the validated and user-confirmed paths so confirmation
    /// skips the model, not the safeguards.
    private func store(
        _ normalized: String,
        source: MemorySource,
        metadata: [String: JSONValue]
    ) async throws -> MemoryGateDecision {
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
}
