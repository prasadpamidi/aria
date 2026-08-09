@testable import Aria
import AriaTesting
import XCTest

// MARK: - MemoryProvenanceTests

/// A fact about the user must come from the user.
///
/// Asked "How am I doing with fasting?", a model called `remember_fact`
/// with "I currently practice fasting successfully for 8 days straight"
/// — a sentence nobody had said. It passed validation (first-person,
/// durable, specific), was written to durable memory, recalled on the
/// next turn, and answered from as fact.
///
/// Validation cannot catch that. It asks whether something *is* a fact;
/// the only question that separates this case is whether the user
/// *said* it.
final class MemoryProvenanceTests: XCTestCase {
    // MARK: - The field failure

    func testInventedFactIsRejected() async throws {
        let gate = Self.gate()
        let decision = try await gate.propose(
            fact: "I currently practice fasting successfully for 8 days straight.",
            source: .toolCall,
            metadata: ["sourceText": .string("How am I doing with fasting?")]
        )
        guard case let .rejected(reason) = decision else {
            return XCTFail("An invented fact must not reach durable memory")
        }
        XCTAssertTrue(reason.contains("not something the user said"), reason)
    }

    /// The check must not break ordinary saves. A validator normally
    /// rewrites the user's words, so paraphrase has to pass.
    func testUserStatedFactIsAccepted() async throws {
        let gate = Self.gate()
        let decision = try await gate.propose(
            fact: "user is vegetarian",
            source: .toolCall,
            metadata: ["sourceText": .string("I'm vegetarian, by the way")]
        )
        guard case .accepted = decision else {
            return XCTFail("A fact the user stated must be saved")
        }
    }

    func testRewrittenFactStillPasses() async throws {
        let gate = Self.gate()
        let decision = try await gate.propose(
            fact: "user lives in Berlin",
            source: .toolCall,
            metadata: ["sourceText": .string("remember I'm in Berlin now")]
        )
        guard case .accepted = decision else {
            return XCTFail("Normalised phrasing must still be saved")
        }
    }

    /// Callers that supply no provenance are unaffected — the check is
    /// opt-in so it cannot silently break existing writers.
    func testAbsentProvenanceSkipsTheCheck() async throws {
        let gate = Self.gate()
        let decision = try await gate.propose(
            fact: "user is vegetarian",
            source: .toolCall,
            metadata: [:]
        )
        guard case .accepted = decision else {
            return XCTFail("Without sourceText the gate behaves as before")
        }
    }

    // MARK: - The matcher

    /// Grammar alone must not count as grounding: "user is …" against
    /// "I am …" shares only scaffolding, and if that passed, every
    /// invention would.
    func testScaffoldingAloneIsNotGrounding() {
        XCTAssertFalse(
            ValidatingMemoryGate.isGrounded("user has been that", in: "you are the one")
        )
    }

    func testProposalMostlyPresentInTheUsersWordsPasses() {
        XCTAssertTrue(
            ValidatingMemoryGate.isGrounded("user is vegetarian", in: "I am vegetarian")
        )
    }

    /// The precise shape of the field failure: one borrowed topic word,
    /// everything else invented.
    func testBorrowingOneTopicWordIsNotGrounding() {
        XCTAssertFalse(
            ValidatingMemoryGate.isGrounded(
                "user practices fasting successfully for 8 days straight",
                in: "How am I doing with fasting?"
            )
        )
    }

    // MARK: Private

    private static func gate() -> ValidatingMemoryGate {
        let embedder = HashEmbedder(dimensions: 64)
        return ValidatingMemoryGate(
            store: DefaultMemoryStore(
                embedder: embedder,
                store: InMemoryVectorStore(dimensions: embedder.dimensions)
            ),
            namespace: ["t"],
            dedupThreshold: nil,
            normalize: { fact, _ in fact }
        )
    }
}

// MARK: - UserConfirmationTests

/// A fact the user confirmed does not need the model's permission.
///
/// `normalize` usually calls a language model and is fail-closed, which
/// is right for a model-proposed fact and wrong for one a person read
/// and tapped Save on. In the field FoundationModels failed mid-turn,
/// the user confirmed "I live in Dublin, CA", and the write was refused
/// with "Couldn't save that one."
final class UserConfirmationTests: XCTestCase {
    /// The field failure: a broken validator must not override the user.
    func testConfirmedFactSavesWhenTheValidatorIsDown() async throws {
        let gate = Self.gate(normalize: { _, _ in
            throw AgentError.providerFailed("validator unavailable", underlying: nil)
        })

        let decision = try await gate.propose(
            fact: "user lives in Dublin, CA",
            source: .toolCall,
            metadata: ["confirmed": .bool(true)]
        )

        guard case .accepted = decision else {
            return XCTFail("A confirmed fact must not depend on a working validator")
        }
    }

    /// Without confirmation the validator still governs — an outage
    /// must not become an open door for model-proposed facts.
    func testUnconfirmedFactStillFailsClosed() async throws {
        let gate = Self.gate(normalize: { _, _ in
            throw AgentError.providerFailed("validator unavailable", underlying: nil)
        })

        let decision = try await gate.propose(
            fact: "user lives in Dublin, CA",
            source: .toolCall,
            metadata: [:]
        )

        guard case .rejected = decision else {
            return XCTFail("Unvetted model content must not reach storage")
        }
    }

    /// Confirmation skips the model, not the safeguards.
    func testConfirmedFactsAreStillDeduplicated() async throws {
        let gate = Self.gate(normalize: { fact, _ in fact }, dedupThreshold: 0.99)
        let metadata: [String: JSONValue] = ["confirmed": .bool(true)]

        _ = try await gate.propose(fact: "user lives in Dublin", source: .toolCall, metadata: metadata)
        let second = try await gate.propose(
            fact: "user lives in Dublin",
            source: .toolCall,
            metadata: metadata
        )

        guard case .duplicate = second else {
            return XCTFail("Confirming twice must not store twice")
        }
    }

    func testConfirmedEmptyFactIsStillRejected() async throws {
        let gate = Self.gate(normalize: { fact, _ in fact })
        let decision = try await gate.propose(
            fact: "   ",
            source: .toolCall,
            metadata: ["confirmed": .bool(true)]
        )
        guard case .rejected = decision else {
            return XCTFail("Empty is empty, however it arrived")
        }
    }

    // MARK: Private

    private static func gate(
        normalize: @escaping @Sendable (String, MemorySource) async throws -> String?,
        dedupThreshold: Float? = nil
    ) -> ValidatingMemoryGate {
        let embedder = HashEmbedder(dimensions: 64)
        return ValidatingMemoryGate(
            store: DefaultMemoryStore(
                embedder: embedder,
                store: InMemoryVectorStore(dimensions: embedder.dimensions)
            ),
            namespace: ["t"],
            dedupThreshold: dedupThreshold,
            normalize: normalize
        )
    }
}

// MARK: - CanonicalFormTests

/// Every stored fact must share one form, or dedup cannot see
/// duplicates.
///
/// The first confirmation bypass stored text verbatim, so
/// `remember_fact` wrote "I live in Dublin, CA" while extraction wrote
/// "user lives in Dublin, CA" — one fact, two rows, because dedup
/// compares embeddings and two phrasings sit far enough apart.
final class CanonicalFormTests: XCTestCase {
    func testConfirmedFactsAreStillCanonicalised() async throws {
        let gate = Self.gate(normalize: { _, _ in "user lives in Dublin, CA" })

        let decision = try await gate.propose(
            fact: "I live in Dublin, CA",
            source: .toolCall,
            metadata: ["confirmed": .bool(true)]
        )

        guard case let .accepted(_, stored) = decision else {
            return XCTFail("expected the fact to be saved")
        }
        XCTAssertEqual(stored, "user lives in Dublin, CA")
    }

    /// And the property that made the bypass necessary survives: a
    /// validator that refuses must not lose a confirmed fact.
    func testRefusedCanonicalisationFallsBackToTheUsersWords() async throws {
        let gate = Self.gate(normalize: { _, _ in nil })

        let decision = try await gate.propose(
            fact: "I live in Dublin, CA",
            source: .toolCall,
            metadata: ["confirmed": .bool(true)]
        )

        guard case let .accepted(_, stored) = decision else {
            return XCTFail("A confirmed fact must survive a refusing validator")
        }
        XCTAssertEqual(stored, "I live in Dublin, CA")
    }

    /// A blank normalisation is not a canonical form.
    func testBlankCanonicalisationFallsBackToo() async throws {
        let gate = Self.gate(normalize: { _, _ in "   " })

        let decision = try await gate.propose(
            fact: "I live in Dublin, CA",
            source: .toolCall,
            metadata: ["confirmed": .bool(true)]
        )

        guard case let .accepted(_, stored) = decision else {
            return XCTFail("expected the fact to be saved")
        }
        XCTAssertEqual(stored, "I live in Dublin, CA")
    }

    private static func gate(
        normalize: @escaping @Sendable (String, MemorySource) async throws -> String?
    ) -> ValidatingMemoryGate {
        let embedder = HashEmbedder(dimensions: 64)
        return ValidatingMemoryGate(
            store: DefaultMemoryStore(
                embedder: embedder,
                store: InMemoryVectorStore(dimensions: embedder.dimensions)
            ),
            namespace: ["t"],
            dedupThreshold: nil,
            normalize: normalize
        )
    }
}
