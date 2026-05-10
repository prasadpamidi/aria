import Foundation

// MARK: - MemoryItem

/// A single recallable fact: a piece of text plus arbitrary metadata.
public struct MemoryItem: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: String = UUID().uuidString,
        content: String,
        metadata: [String: JSONValue] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.metadata = metadata
        self.createdAt = createdAt
    }

    // MARK: Public

    public let id: String
    public let content: String
    public let metadata: [String: JSONValue]
    public let createdAt: Date
}

// MARK: - MemoryMatch

/// A match returned by `MemoryStore.recall`.
public struct MemoryMatch: Sendable, Equatable {
    // MARK: Lifecycle

    public init(item: MemoryItem, score: Float) {
        self.item = item
        self.score = score
    }

    // MARK: Public

    public let item: MemoryItem
    public let score: Float
}

// MARK: - MemoryRef

/// A handle returned by `MemoryStore.remember`. Carries enough
/// information to forget the entry later.
public struct MemoryRef: Sendable, Equatable {
    // MARK: Lifecycle

    public init(id: String, namespace: [String]) {
        self.id = id
        self.namespace = namespace
    }

    // MARK: Public

    public let id: String
    public let namespace: [String]
}

// MARK: - MemoryStore

/// High-level "remember / recall" API.
///
/// `MemoryStore` is the convenience layer agents and consumers usually
/// interact with directly. It composes an `Embedder` (text → vectors)
/// with a `VectorStore` (similarity search) plus a namespace scheme so
/// per-user / per-domain isolation is straightforward.
public protocol MemoryStore: Sendable {
    /// Persist a memory inside `namespace`. Returns the resulting
    /// reference for later `forget`.
    func remember(_ item: MemoryItem, namespace: [String]) async throws -> MemoryRef

    /// Find memories most similar to `query` inside `namespace`.
    /// Optional `filter` narrows by additional metadata predicates.
    func recall(
        query: String,
        namespace: [String],
        topK: Int,
        filter: VectorFilter?
    ) async throws -> [MemoryMatch]

    /// Remove the named memory from the namespace.
    func forget(id: String, namespace: [String]) async throws

    /// Enumerate stored memories inside `namespace` without a query.
    func list(namespace: [String], limit: Int) async throws -> [MemoryItem]
}

// MARK: - DefaultMemoryStore

/// The reference `MemoryStore` implementation: composes an `Embedder`
/// with a `VectorStore`.
///
/// Namespace support is implemented by stamping every stored vector
/// with a `__namespace__` metadata key and filtering on it during
/// recall. Consumers' own metadata keys are passed through unchanged.
public struct DefaultMemoryStore: MemoryStore {
    // MARK: Lifecycle

    public init(embedder: any Embedder, store: any VectorStore) {
        self.embedder = embedder
        self.store = store
    }

    // MARK: Public

    public func remember(
        _ item: MemoryItem,
        namespace: [String]
    ) async throws -> MemoryRef {
        let vector = try await self.embedder.embed(item.content)
        let metadata = self.augment(item.metadata, withNamespace: namespace, item: item)
        try await self.store.upsert([
            VectorItem(
                id: item.id,
                vector: vector,
                content: item.content,
                metadata: metadata
            ),
        ])
        return MemoryRef(id: item.id, namespace: namespace)
    }

    public func recall(
        query: String,
        namespace: [String],
        topK: Int,
        filter: VectorFilter?
    ) async throws -> [MemoryMatch] {
        let vector = try await self.embedder.embed(query)
        let combined = self.combinedFilter(namespace: namespace, additional: filter)
        let matches = try await self.store.search(
            query: vector,
            topK: topK,
            filter: combined
        )
        return matches.map { match in
            MemoryMatch(
                item: Self.memoryItem(from: match),
                score: match.score
            )
        }
    }

    public func forget(id: String, namespace _: [String]) async throws {
        try await self.store.delete(ids: [id])
    }

    public func list(namespace: [String], limit: Int) async throws -> [MemoryItem] {
        let combined = self.combinedFilter(namespace: namespace, additional: nil)
        let items = try await self.store.list(filter: combined, limit: limit)
        return items.map { item in
            Self.memoryItem(from: item)
        }
    }

    // MARK: Internal

    static let namespaceKey = "__aria_namespace__"
    static let createdAtKey = "__aria_createdAt__"

    // MARK: Private

    private let embedder: any Embedder
    private let store: any VectorStore

    private static func memoryItem(from match: VectorMatch) -> MemoryItem {
        self.memoryItem(
            id: match.id,
            content: match.content,
            metadata: match.metadata
        )
    }

    private static func memoryItem(from item: VectorItem) -> MemoryItem {
        self.memoryItem(
            id: item.id,
            content: item.content,
            metadata: item.metadata
        )
    }

    private static func memoryItem(
        id: String,
        content: String,
        metadata: [String: JSONValue]
    ) -> MemoryItem {
        var clean = metadata
        clean.removeValue(forKey: Self.namespaceKey)
        let createdAt: Date
        if case let .number(timestamp) = metadata[Self.createdAtKey] {
            createdAt = Date(timeIntervalSince1970: timestamp)
            clean.removeValue(forKey: Self.createdAtKey)
        } else {
            createdAt = Date()
        }
        return MemoryItem(
            id: id,
            content: content,
            metadata: clean,
            createdAt: createdAt
        )
    }

    private func augment(
        _ metadata: [String: JSONValue],
        withNamespace namespace: [String],
        item: MemoryItem
    ) -> [String: JSONValue] {
        var augmented = metadata
        augmented[Self.namespaceKey] = .string(namespace.joined(separator: "/"))
        augmented[Self.createdAtKey] = .number(item.createdAt.timeIntervalSince1970)
        return augmented
    }

    private func combinedFilter(
        namespace: [String],
        additional: VectorFilter?
    ) -> VectorFilter {
        let nsFilter = VectorFilter.equals(
            field: Self.namespaceKey,
            value: .string(namespace.joined(separator: "/"))
        )
        if let additional {
            return .and([nsFilter, additional])
        }
        return nsFilter
    }
}
