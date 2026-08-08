import Foundation

// MARK: - ToolSelector

/// Chooses which tools to send for a given turn.
///
/// Sending every registered tool on every turn is the default behaviour
/// almost everywhere, and it stops scaling as soon as an app exposes
/// plugins or connects an MCP server. A surface of seventy tools costs
/// thousands of tokens per request whether or not any of them relate to
/// what the user asked, and small models degrade sharply when the
/// instruction-to-content ratio gets that lopsided.
///
/// Implementations rank `ToolDefinition` values — pure data, no
/// invocation closures — so selection stays testable in isolation and
/// portable across the retrieval strategies that might back it.
public protocol ToolSelector: Sendable {
    /// - Parameters:
    ///   - tools: Every tool the agent has registered.
    ///   - query: Text to rank against, normally the latest user turn.
    ///   - limit: Maximum tools to return.
    /// - Returns: Up to `limit` tools, most relevant first. May return
    ///   fewer, including none, when nothing is relevant — callers that
    ///   need a tool guaranteed present should pin it rather than rely
    ///   on ranking.
    func select(
        from tools: [ToolDefinition],
        query: String,
        limit: Int
    ) async -> [ToolDefinition]
}

extension Character {
    /// Vowel test used by suffix folding's doubled-consonant rule.
    fileprivate var isVowel: Bool {
        "aeiou".contains(self)
    }
}

// MARK: - LexicalToolSelector

/// Term-overlap ranking with inverse-document-frequency weighting.
///
/// The default selector. It carries no model, no dependency, and no
/// measurable latency, which makes it a reasonable floor rather than a
/// ceiling: a retrieval model such as a ColBERT-style late-interaction
/// scorer conforms to the same protocol and can replace it without
/// touching a call site.
///
/// IDF matters more than it might seem. Tool descriptions share a lot
/// of filler ("the", "a", "returns", "given"), and unweighted overlap
/// lets that filler dominate — every tool matches every query weakly
/// and ranking turns to noise. Weighting by rarity across the tool
/// corpus makes distinctive terms decide the outcome.
///
/// Known limitation: this is lexical, so it matches words rather than
/// meaning. "What did I eat?" will not surface `log_meal` unless the
/// description happens to contain a shared term. That gap is precisely
/// what an embedding-based selector closes.
public struct LexicalToolSelector: ToolSelector {
    // MARK: Lifecycle

    public init(minimumScore: Double = 0.0) {
        self.minimumScore = minimumScore
    }

    // MARK: Public

    public func select(
        from tools: [ToolDefinition],
        query: String,
        limit: Int
    ) async -> [ToolDefinition] {
        guard limit > 0, !tools.isEmpty else {
            return []
        }
        let queryTerms = Set(Self.tokenize(query)).subtracting(Self.stopWords)
        guard !queryTerms.isEmpty else {
            return []
        }

        // Document frequency across the tool corpus, for IDF.
        let documents = tools.map { Set(Self.tokenize(Self.searchableText(for: $0))) }
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in document {
                documentFrequency[term, default: 0] += 1
            }
        }

        let corpusSize = Double(tools.count)
        // Pair each tool with its score and original position so ties
        // resolve to registration order rather than arbitrarily.
        var scored: [ScoredTool] = []
        scored.reserveCapacity(tools.count)

        for index in tools.indices {
            let terms = documents[index]
            var score = 0.0
            for term in queryTerms where terms.contains(term) {
                let frequency = Double(documentFrequency[term] ?? 1)
                // Smoothed IDF; a term present in every tool
                // contributes almost nothing.
                score += log(1.0 + corpusSize / frequency)
            }
            guard score > self.minimumScore else {
                continue
            }
            scored.append(ScoredTool(index: index, tool: tools[index], score: score))
        }

        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        return scored.prefix(limit).map(\.tool)
    }

    // MARK: Internal

    /// Terms carrying no signal about which tool is wanted.
    ///
    /// IDF weights by rarity *within the tool corpus*, which is not the
    /// same as informativeness — and the two come apart exactly here.
    /// Across twenty tools the word "quick" appears about once, so IDF
    /// scores it as highly discriminative and "give me a quick recipe
    /// idea" selects `run_quick_add_to_groceries_remix`. The adjective
    /// decided the match; "recipe", the word that mattered, matched
    /// nothing.
    ///
    /// A corpus-statistical measure cannot notice this on its own,
    /// because in a small corpus a junk term genuinely is rare. The
    /// list is short on purpose: generic verbs and adjectives that
    /// appear in requests regardless of intent. Anything domain-shaped
    /// stays in, since a stopword list that grows starts deleting
    /// meaning.
    static let stopWords: Set<String> = [
        "give", "get", "make", "show", "tell", "find", "help", "want",
        "need", "like", "know", "think", "look", "try", "use", "have",
        "quick", "fast", "easy", "simple", "good", "nice", "new", "best",
        "some", "any", "thing", "idea", "please", "can", "could", "would",
        "about", "with", "for", "the", "and", "you", "your", "what",
        "how", "why", "when", "where", "who", "this", "that",
        // Words that frame *when* something holds rather than *what* is
        // being asked about. "What's my current weight?" scored
        // `current_time` and `get_weather` on "current", sent nothing
        // about weight, and left the model with no tool that could
        // answer — the "quick" failure again with a different
        // adjective. Recency words attach to any request regardless of
        // its subject, which is exactly the property that makes them
        // worthless for telling tools apart.
        "current", "currently", "now", "today", "latest", "recent",
    ]

    /// Lowercased alphanumeric terms, split on punctuation *and*
    /// camelCase boundaries.
    ///
    /// Tool names are identifiers — `log_meal`, `getWeather`,
    /// `shopping-list` — so a tokenizer that only splits on whitespace
    /// would treat each whole name as one opaque term and match almost
    /// nothing. Splitting identifiers into their words is what lets a
    /// query like "log my meal" reach `log_meal` at all.
    static func tokenize(_ text: String) -> [String] {
        var terms: [String] = []
        var current = ""

        func flush() {
            if current.count > 1 {
                terms.append(Self.fold(current.lowercased()))
            }
            current = ""
        }

        var previous: Character?
        for character in text {
            if character.isLetter || character.isNumber {
                // camelCase boundary: lower/digit followed by upper.
                if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                    flush()
                }
                current.append(character)
            } else {
                flush()
            }
            previous = character
        }
        flush()
        return terms
    }

    /// Collapse the commonest English inflections so a query and a
    /// description can agree without matching character-for-character.
    ///
    /// "meals" should reach `log_meal`; "logging" should reach "log".
    /// This is not stemming — a real stemmer is a dependency and a
    /// source of surprising collisions. It handles the three suffixes
    /// that account for most near-misses and stops there, deliberately
    /// leaving longer words alone since truncating short ones creates
    /// false matches ("uses" → "use" is fine, "bus" → "bu" is not).
    static func fold(_ term: String) -> String {
        guard term.count > 4 else {
            return term
        }
        for suffix in ["ing", "es", "s"] where term.hasSuffix(suffix) {
            var stem = String(term.dropLast(suffix.count))
            guard stem.count >= 3 else {
                continue
            }
            // English doubles a final consonant before "-ing":
            // shopping → shopp, logging → logg, running → runn.
            // Leaving the double in place would strand the folded
            // term away from the plain word a user actually types
            // ("shop" ≠ "shopp"), which loses the very match this
            // folding exists to create.
            if suffix == "ing", let last = stem.last, stem.dropLast().last == last, !last.isVowel {
                stem = String(stem.dropLast())
            }
            return stem
        }
        return term
    }

    // MARK: Private

    /// Named rather than a tuple so the scoring loop stays cheap for
    /// the type checker.
    private struct ScoredTool {
        let index: Int
        let tool: ToolDefinition
        let score: Double
    }

    private let minimumScore: Double

    /// Name, description, and parameter names.
    ///
    /// Parameter names carry real signal that name and description
    /// often miss. A tool called `log_activity` described as "Record an
    /// activity" shares no term with "log my run" beyond "log" — but a
    /// `distance` or `duration` parameter reaches queries the prose
    /// never will. Schemas are already written; indexing them costs
    /// nothing and measurably widens recall.
    ///
    /// Recall is the failure mode that matters here. A tool ranked too
    /// low is invisible to the model, which cannot then call it — and
    /// that is indistinguishable, from the outside, from a model that
    /// simply refuses to use tools.
    private static func searchableText(for tool: ToolDefinition) -> String {
        var parts = [tool.name, tool.description]
        parts.append(contentsOf: Self.parameterNames(in: tool.inputSchema))
        return parts.joined(separator: " ")
    }

    /// Top-level property names of an object schema.
    ///
    /// Deliberately shallow: nested schemas describe the shape of a
    /// value rather than what the tool is *for*, and indexing them
    /// dilutes IDF with structural noise.
    private static func parameterNames(in schema: JSONSchema) -> [String] {
        guard case let .object(properties, _, _, _) = schema else {
            return []
        }
        return Array(properties.keys)
    }
}
