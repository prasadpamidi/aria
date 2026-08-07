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
        let queryTerms = Set(Self.tokenize(query))
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
                terms.append(current.lowercased())
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

    // MARK: Private

    /// Named rather than a tuple so the scoring loop stays cheap for
    /// the type checker.
    private struct ScoredTool {
        let index: Int
        let tool: ToolDefinition
        let score: Double
    }

    private let minimumScore: Double

    private static func searchableText(for tool: ToolDefinition) -> String {
        "\(tool.name) \(tool.description)"
    }
}
