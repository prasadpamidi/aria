import Foundation

// MARK: - EmbeddingToolSelector

/// Ranks tools by semantic similarity rather than shared words.
///
/// `LexicalToolSelector` scores term overlap weighted by rarity across
/// the tool corpus, and its failures all have one shape: a word that is
/// common in English but rare among thirty tool descriptions gets
/// treated as highly discriminative. "give me a quick recipe idea"
/// selected a groceries tool on the word "quick"; "What's my current
/// weight?" selected a clock and a weather tool on the word "current".
/// Both were patched by adding words to a stopword list, which is
/// hand-encoding English word-frequency one failure at a time and
/// cannot be finished.
///
/// Embeddings measure the thing that was actually wanted. They also
/// close a gap no stopword list can reach: "what did I eat?" shares no
/// term with "Record a meal the user ate", and lexical ranking cannot
/// connect them at any threshold.
///
/// **The embedder is injected**, so this stays in core with no model
/// dependency. `NLEmbeddingEmbedder` in `AriaApple` ships with the OS
/// at no binary cost; an MLX or Core ML embedder conforms to the same
/// protocol when higher fidelity is worth the download.
///
/// Vectors for tool descriptions are cached, keyed by content, because
/// the corpus is nearly constant across turns while the query changes
/// every time. A cold turn embeds the whole corpus once; every turn
/// after embeds one string.
public actor EmbeddingToolSelector: ToolSelector {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - embedder: Produces the vectors. Its `modelIdentifier` is
    ///     part of the cache key, so swapping models cannot serve
    ///     vectors from the previous one.
    ///   - minimumSimilarity: Cosine floor below which a tool is not
    ///     considered relevant.
    ///
    ///     Load-bearing, and not just a quality knob. `DefaultContext
    ///     Assembler` reads an empty ranking as "the ranker had nothing
    ///     to say" and falls back to sending everything that fits. A
    ///     selector that always returns its full input — which cosine
    ///     ranking does without a floor, since every pair has *some*
    ///     similarity — would silently disable that fallback and make
    ///     every turn look confidently ranked.
    ///   - fallback: Consulted when the embedder fails or returns
    ///     nothing above the floor. Embedding is a network- and
    ///     model-dependent step in a path that must not lose the
    ///     ability to rank at all.
    public init(
        embedder: any Embedder,
        minimumSimilarity: Double = 0.25,
        fallback: (any ToolSelector)? = LexicalToolSelector()
    ) {
        self.embedder = embedder
        self.minimumSimilarity = minimumSimilarity
        self.fallback = fallback
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        guard let queryVector = await self.vector(for: trimmed) else {
            return await self.fallbackSelect(tools, query: query, limit: limit)
        }

        var scored: [(index: Int, tool: ToolDefinition, score: Double)] = []
        for index in tools.indices {
            let tool = tools[index]
            guard let toolVector = await self.vector(for: Self.searchableText(for: tool)) else {
                continue
            }
            let score = Self.cosine(queryVector, toolVector)
            guard score >= self.minimumSimilarity else {
                continue
            }
            scored.append((index, tool, score))
        }

        guard !scored.isEmpty else {
            return await self.fallbackSelect(tools, query: query, limit: limit)
        }

        // Ties resolve to registration order rather than arbitrarily,
        // matching `LexicalToolSelector` so a swap doesn't reshuffle
        // equally-scored tools.
        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        return scored.prefix(limit).map(\.tool)
    }

    // MARK: Internal

    /// The text a tool is ranked by. Name included because identifiers
    /// carry intent — `get_weight_trend` says what a terse description
    /// may not.
    static func searchableText(for tool: ToolDefinition) -> String {
        let words = tool.name
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .joined(separator: " ")
        return "\(words). \(tool.description)"
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return 0
        }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        guard lhsNorm > 0, rhsNorm > 0 else {
            return 0
        }
        return dot / (lhsNorm.squareRoot() * rhsNorm.squareRoot())
    }

    // MARK: Private

    private let embedder: any Embedder
    private let minimumSimilarity: Double
    private let fallback: (any ToolSelector)?

    /// Keyed by model identifier and content, so neither a swapped
    /// embedder nor an edited description can be served a stale vector.
    private var cache: [String: [Double]] = [:]

    private func vector(for text: String) async -> [Double]? {
        let key = "\(self.embedder.modelIdentifier)\u{1}\(text)"
        if let cached = cache[key] {
            return cached
        }
        guard let vector = try? await embedder.embed(text), !vector.isEmpty else {
            return nil
        }
        let doubles = vector.map(Double.init)
        self.cache[key] = doubles
        return doubles
    }

    private func fallbackSelect(
        _ tools: [ToolDefinition],
        query: String,
        limit: Int
    ) async -> [ToolDefinition] {
        guard let fallback else {
            return []
        }
        return await fallback.select(from: tools, query: query, limit: limit)
    }
}
