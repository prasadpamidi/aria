import Foundation

// MARK: - VectorItem

/// An entry stored in a `VectorStore`: an embedding, the original text,
/// and arbitrary key-value metadata for filtering.
public struct VectorItem: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: String,
        vector: [Float],
        content: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.vector = vector
        self.content = content
        self.metadata = metadata
    }

    // MARK: Public

    public let id: String
    public let vector: [Float]
    public let content: String
    public let metadata: [String: JSONValue]
}

// MARK: - VectorMatch

/// A search hit returned by `VectorStore.search`.
public struct VectorMatch: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: String,
        score: Float,
        content: String,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.score = score
        self.content = content
        self.metadata = metadata
    }

    // MARK: Public

    public let id: String
    public let score: Float
    public let content: String
    public let metadata: [String: JSONValue]
}

// MARK: - VectorFilter

/// Boolean predicate over `VectorItem.metadata`. Stores translate this
/// into their native query language.
public indirect enum VectorFilter: Sendable, Equatable {
    case equals(field: String, value: JSONValue)
    case notEquals(field: String, value: JSONValue)
    case `in`(field: String, values: [JSONValue])
    case and([VectorFilter])
    case or([VectorFilter])
}

extension VectorFilter {
    /// Evaluate this filter against a metadata bag. Used by stores that
    /// don't have a native filter language (e.g., `InMemoryVectorStore`).
    public func matches(_ metadata: [String: JSONValue]) -> Bool {
        switch self {
        case let .equals(field, value):
            metadata[field] == value
        case let .notEquals(field, value):
            metadata[field] != value
        case let .in(field, values):
            (metadata[field].map { values.contains($0) }) ?? false
        case let .and(filters):
            filters.allSatisfy { $0.matches(metadata) }
        case let .or(filters):
            filters.contains { $0.matches(metadata) }
        }
    }
}

// MARK: - VectorStore

/// Stores embeddings + metadata and supports similarity search.
///
/// Implementations may use brute-force scan (suitable for small
/// datasets) or proper ANN indexes (HNSW, IVF, etc.). Aria ships an
/// `InMemoryVectorStore` for tests and small corpora; persistent
/// implementations live in platform modules.
public protocol VectorStore: Sendable {
    /// Dimensionality of vectors this store accepts. Mismatched inputs
    /// throw `AgentError.configurationInvalid`.
    var dimensions: Int { get }

    /// Insert or replace items by id.
    func upsert(_ items: [VectorItem]) async throws

    /// Cosine-similarity (or implementation-defined) search. Higher
    /// score = more similar. Filter narrows the candidate set before
    /// ranking.
    func search(
        query: [Float],
        topK: Int,
        filter: VectorFilter?
    ) async throws -> [VectorMatch]

    /// Remove items by id.
    func delete(ids: [String]) async throws

    /// Number of items, optionally filtered.
    func count(filter: VectorFilter?) async throws -> Int

    /// Enumerate items without ranking. Useful for migration, export,
    /// and high-level "list what I've remembered" UIs.
    func list(filter: VectorFilter?, limit: Int) async throws -> [VectorItem]
}

// MARK: - InMemoryVectorStore

/// A `VectorStore` backed by an actor-isolated dictionary, scoring with
/// cosine similarity over the full set on every search.
///
/// Suitable for tests, small corpora (<10k items), and Linux test runs.
/// For larger workloads use a persistent implementation backed by an ANN
/// index (e.g., the upcoming `SQLiteVecVectorStore` in `AriaApple`).
public actor InMemoryVectorStore: VectorStore {
    // MARK: Lifecycle

    public init(dimensions: Int) {
        self.dimensions = dimensions
    }

    // MARK: Public

    public let dimensions: Int

    public func upsert(_ items: [VectorItem]) async throws {
        for item in items {
            try self.validate(item.vector)
            self.store[item.id] = item
        }
    }

    public func search(
        query: [Float],
        topK: Int,
        filter: VectorFilter?
    ) async throws -> [VectorMatch] {
        try self.validate(query)
        let candidates = self.candidates(filter: filter)
        let scored = candidates.map { item in
            (item, Self.cosineSimilarity(query, item.vector))
        }
        let top = scored
            .sorted { $0.1 > $1.1 }
            .prefix(max(0, topK))
        return top.map { item, score in
            VectorMatch(
                id: item.id,
                score: score,
                content: item.content,
                metadata: item.metadata
            )
        }
    }

    public func delete(ids: [String]) async throws {
        for id in ids {
            self.store.removeValue(forKey: id)
        }
    }

    public func count(filter: VectorFilter?) async throws -> Int {
        self.candidates(filter: filter).count
    }

    public func list(filter: VectorFilter?, limit: Int) async throws -> [VectorItem] {
        let candidates = self.candidates(filter: filter)
        if limit < candidates.count {
            return Array(candidates.prefix(limit))
        }
        return candidates
    }

    // MARK: Internal

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var dot: Float = 0
        var magLHS: Float = 0
        var magRHS: Float = 0
        for index in 0..<lhs.count {
            dot += lhs[index] * rhs[index]
            magLHS += lhs[index] * lhs[index]
            magRHS += rhs[index] * rhs[index]
        }
        let denom = (magLHS * magRHS).squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    // MARK: Private

    private var store: [String: VectorItem] = [:]

    private func validate(_ vector: [Float]) throws {
        guard vector.count == self.dimensions else {
            throw AgentError.configurationInvalid(
                "Vector has \(vector.count) dimensions but store expects \(self.dimensions)"
            )
        }
    }

    private func candidates(filter: VectorFilter?) -> [VectorItem] {
        guard let filter else {
            return Array(self.store.values)
        }
        return self.store.values.filter { filter.matches($0.metadata) }
    }
}
