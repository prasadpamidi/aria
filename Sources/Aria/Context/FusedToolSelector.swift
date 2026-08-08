import Foundation

// MARK: - FusedToolSelector

/// Combines several rankers by reciprocal rank fusion.
///
/// Measured on the field corpus, lexical and embedding ranking fail on
/// *different* queries. Lexical cannot connect "what did I eat today?"
/// to "Record a meal the user ate" — no shared term, no threshold that
/// helps. Embedding handles that and then ranks `load_skill` above a
/// weight tool for "What's my current weight?", because a weak sentence
/// embedding puts everything vaguely user-shaped near everything else.
///
/// Fusion is worth trying precisely because the errors are
/// uncorrelated: a tool has to be missed by *both* rankers to be
/// missed overall.
///
/// RRF rather than score averaging, because the two scales have nothing
/// to do with each other — summed IDF is unbounded while cosine sits in
/// [-1, 1], and normalising them against each other would invent a
/// relationship that isn't there. Rank is the only quantity both
/// produce that means the same thing.
public struct FusedToolSelector: ToolSelector {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - selectors: Rankers to fuse, best-understood first — ties
    ///     resolve toward earlier selectors.
    ///   - depth: How far down each ranking to consider. Fusing the
    ///     full list would let a ranker that returns everything
    ///     outvote one that returns only what it is confident about.
    ///   - dampening: The `k` in `1 / (k + rank)`. Larger values
    ///     flatten the contribution of top ranks, so agreement across
    ///     rankers matters more than any single ranker's confidence.
    ///     60 is the value from the original RRF paper.
    public init(
        selectors: [any ToolSelector],
        depth: Int = 10,
        dampening: Double = 60
    ) {
        self.selectors = selectors
        self.depth = max(1, depth)
        self.dampening = max(1, dampening)
    }

    // MARK: Public

    public func select(
        from tools: [ToolDefinition],
        query: String,
        limit: Int
    ) async -> [ToolDefinition] {
        guard limit > 0, !tools.isEmpty, !self.selectors.isEmpty else {
            return []
        }

        var scores: [String: Double] = [:]
        for selector in self.selectors {
            let ranked = await selector.select(from: tools, query: query, limit: self.depth)
            for (rank, tool) in ranked.enumerated() {
                scores[tool.name, default: 0] += 1.0 / (self.dampening + Double(rank + 1))
            }
        }

        // Every ranker declining to rank anything still means "no
        // signal" — the assembler reads an empty result as licence to
        // send whatever fits, and fusion must not manufacture a ranking
        // out of unanimous silence.
        guard !scores.isEmpty else {
            return []
        }

        let position = Dictionary(
            tools.enumerated().map { ($0.element.name, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return tools
            .filter { scores[$0.name] != nil }
            .sorted { lhs, rhs in
                let lhsScore = scores[lhs.name] ?? 0
                let rhsScore = scores[rhs.name] ?? 0
                if lhsScore == rhsScore {
                    return (position[lhs.name] ?? 0) < (position[rhs.name] ?? 0)
                }
                return lhsScore > rhsScore
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Private

    private let selectors: [any ToolSelector]
    private let depth: Int
    private let dampening: Double
}
