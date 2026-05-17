# Layer 4 — Memory

Memory in Aria is split into four orthogonal protocols, each addressing one concern. Conflating them is a common LangChain mistake; Aria keeps them separate.

| Protocol | Concern | Lifetime |
|---|---|---|
| `ChatHistory` | Messages in this conversation | Per-thread |
| `Checkpointer` | Full agent state at each step | Per-thread, durable |
| `VectorStore` | Similarity search over embeddings | App-managed |
| `MemoryStore` | High-level "remember/recall" | Forever, namespaced |

Plus one stateless **policy** that prunes the disk side:

| Type | Concern | Lifetime |
|---|---|---|
| `HistoryRetentionPolicy` | Whole-thread eviction by age + count | One-shot, idempotent |

The agent layer (Layer 5) consumes these via injection. None are required; agents work without memory. **Shaping the message slice the provider sees per step is a middleware concern** (`HistoryWindowMiddleware`, `HistorySummarizationMiddleware`) — see Layer 5.

## `ChatHistory`

Stores the messages that make up a conversation thread.

```swift
public protocol ChatHistory: Sendable {
    func append(_ message: Message, threadId: String) async throws
    func messages(threadId: String, limit: Int?, before: Date?) async throws -> [Message]
    func clear(threadId: String) async throws
    func threads() async throws -> [String]
}
```

**Design notes:**

- `threadId` is opaque to Aria. Consumers choose: per-conversation, per-user, per-feature.
- `limit` and `before` support paging for long histories.
- `threads()` lets UIs list conversations.
- No "edit message" or "delete message" — chat history is append-only by design. Edits are modeled as new messages.

### In-memory default

```swift
public actor InMemoryChatHistory: ChatHistory {
    private var store: [String: [Message]] = [:]

    public init() {}

    public func append(_ message: Message, threadId: String) async throws {
        store[threadId, default: []].append(message)
    }

    public func messages(threadId: String, limit: Int?, before: Date?) async throws -> [Message] {
        let all = store[threadId] ?? []
        let filtered = before.map { date in all.filter { $0.createdAt < date } } ?? all
        return limit.map { Array(filtered.suffix($0)) } ?? filtered
    }

    public func clear(threadId: String) async throws { store[threadId] = [] }
    public func threads() async throws -> [String] { Array(store.keys) }
}
```

## `Checkpointer`

Saves the full agent state at each step. Used for resume, time-travel, and human-in-the-loop interrupts.

```swift
public protocol Checkpointer: Sendable {
    func put(_ checkpoint: Checkpoint, threadId: String) async throws
    func get(threadId: String, checkpointId: String?) async throws -> Checkpoint?
    func list(threadId: String, limit: Int) async throws -> [Checkpoint]
    func deleteThread(_ threadId: String) async throws
}

public struct Checkpoint: Codable, Sendable {
    public let id: String                    // ULID, time-sortable
    public let threadId: String
    public let parentId: String?             // for branching
    public let createdAt: Date
    public let state: Data                   // serialized AgentState
    public let metadata: [String: JSONValue]
}
```

### Why state is `Data`

The Checkpointer stores opaque bytes; it doesn't know what `AgentState` looks like. The agent serializes/deserializes via `Codable` before/after. This decouples the storage layer from the agent's evolving state shape.

### Why ULID

Lexicographically sortable, time-encoded, unique. Lets you list checkpoints in order without a separate index.

### Use cases

- **Resume:** save checkpoint at each step; on app relaunch, load latest, continue.
- **Time travel:** load any historical checkpoint, branch from it.
- **HITL:** agent emits an interrupt event, the latest checkpoint records the pre-interrupt state, the consumer presents the question to the user, then resumes from the checkpoint after the user answers.

## `VectorStore`

Stores vectors with metadata; performs similarity search.

```swift
public protocol VectorStore: Sendable {
    var dimensions: Int { get }

    func upsert(_ items: [VectorItem]) async throws
    func search(
        query: [Float],
        topK: Int,
        filter: VectorFilter?
    ) async throws -> [VectorMatch]
    func delete(ids: [String]) async throws
    func count(filter: VectorFilter?) async throws -> Int
}

public struct VectorItem: Sendable {
    public let id: String
    public let vector: [Float]
    public let content: String                // the original text
    public let metadata: [String: JSONValue]
}

public struct VectorMatch: Sendable {
    public let id: String
    public let score: Float                   // similarity, higher is better
    public let content: String
    public let metadata: [String: JSONValue]
}

public enum VectorFilter: Sendable {
    case equals(field: String, value: JSONValue)
    case notEquals(field: String, value: JSONValue)
    case `in`(field: String, values: [JSONValue])
    case and([VectorFilter])
    case or([VectorFilter])
}
```

**Design notes:**

- `score` is normalized similarity (cosine, dot product — depends on impl). Higher is better, always.
- `VectorFilter` is structured, not a string DSL. Each backend translates filters to its native query language.
- The store does NOT embed text. The caller provides `[Float]`; the caller called the `Embedder` first. This separation lets you swap embedders without touching the store.

### In-memory default

`InMemoryVectorStore` uses cosine similarity over a flat `[VectorItem]` list. Fine for tests and small datasets (< ~10k items). Real Apple impl uses sqlite-vec.

## `MemoryStore`

A high-level convenience that composes `Embedder` + `VectorStore` + namespacing into a "remember/recall" interface. This is what most application code touches.

```swift
public protocol MemoryStore: Sendable {
    func remember(
        _ item: MemoryItem,
        namespace: [String]
    ) async throws -> MemoryRef

    func recall(
        query: String,
        namespace: [String],
        topK: Int,
        filter: VectorFilter?
    ) async throws -> [MemoryMatch]

    func forget(id: String, namespace: [String]) async throws

    func list(namespace: [String], limit: Int) async throws -> [MemoryItem]
}

public struct MemoryItem: Sendable {
    public let id: String
    public let content: String
    public let metadata: [String: JSONValue]
    public let createdAt: Date
}

public struct MemoryMatch: Sendable {
    public let item: MemoryItem
    public let score: Float
}

public struct MemoryRef: Sendable {
    public let id: String
    public let namespace: [String]
}
```

### Namespacing

`namespace: [String]` is hierarchical. Examples:

- `["user_42", "preferences"]`
- `["user_42", "facts", "work"]`
- `["app", "global", "facts"]`

The store translates namespaces into its underlying filter or partition scheme.

### Default implementation

```swift
public struct DefaultMemoryStore: MemoryStore {
    let embedder: any Embedder
    let store: any VectorStore

    public func remember(_ item: MemoryItem, namespace: [String]) async throws -> MemoryRef {
        let vector = try await embedder.embed(item.content)
        var meta = item.metadata
        meta["__namespace__"] = .string(namespace.joined(separator: "/"))
        try await store.upsert([VectorItem(
            id: item.id,
            vector: vector,
            content: item.content,
            metadata: meta
        )])
        return MemoryRef(id: item.id, namespace: namespace)
    }
    // ... recall, forget, list
}
```

This sits in `Aria` (core) because it's pure protocol composition. Apple platforms get `DefaultMemoryStore(embedder: NLEmbeddingEmbedder(), store: SQLiteVecVectorStore(...))`.

## `HistoryRetentionPolicy`

Stateless policy that bounds the **disk** side of `ChatHistory`. Complements the agent-layer middlewares (`HistoryWindowMiddleware`, `HistorySummarizationMiddleware`) which bound the **wire** side.

```swift
public struct HistoryRetentionPolicy: Sendable {
    public init(
        maxThreadAgeDays: Double? = nil,
        maxThreadCount: Int? = nil
    )

    @discardableResult
    public func enforce(on history: any ChatHistory) async throws -> Report

    public struct Report: Sendable, Equatable {
        public var threadsRemovedForAge: [String]
        public var threadsRemovedForCount: [String]
    }
}
```

**Whole-thread eviction.** `ChatHistory`'s public surface only supports `clear(threadId:)` — drop a whole conversation, not "drop oldest N messages." That's deliberate: per-thread compaction is a middleware concern (`HistorySummarizationMiddleware`); per-thread eviction is the storage concern.

- `maxThreadAgeDays` — a thread whose newest message is older than this gets cleared. Last-activity eviction.
- `maxThreadCount` — after age eviction, if more threads remain than the cap, the oldest-activity threads are dropped until the count fits. LRU-by-last-activity.

**When to run it.** Not on every agent step — too much I/O. The caller decides:

- On app startup (once per process)
- As a scheduled background job (e.g. daily)
- On low-disk-pressure system signals

The policy is stateless and idempotent; calling `enforce(on:)` twice in a row drops the same set the first call drops, then nothing.

```swift
try await HistoryRetentionPolicy(
    maxThreadAgeDays: 90,    // expire threads inactive >90 days
    maxThreadCount: 20       // keep at most 20 threads
).enforce(on: storage.chatHistory)
```

## `HistoryPolicy` *(legacy enum — prefer the middlewares)*

> `HistoryPolicy` is still on `AgentConfig` for backward compatibility, but the recommended approach is to compose the dedicated middlewares (`HistoryWindowMiddleware`, `HistorySummarizationMiddleware`) in `AgentConfig.middleware`. The middleware path gives more control (token-budget caps, dedicated summarizer caching, fail-open behavior) and composes cleanly with the rest of the chain.

Not a memory protocol — a strategy for selecting which messages from `ChatHistory` to send to the model.

```swift
public enum HistoryPolicy: Sendable {
    case keepAll
    case lastN(Int)
    case tokenWindow(maxTokens: Int, tokenizer: any Tokenizer)
    case summarize(threshold: Int, summarizer: any Runnable<[Message], Message>)
    case windowedWithSummary(window: Int, summarizer: any Runnable<[Message], Message>)
    case custom(any HistorySelector)
}

public protocol HistorySelector: Sendable {
    func select(messages: [Message], systemPrompt: String?) async throws -> [Message]
}
```

**Design notes:**

- `summarize` uses a `Runnable<[Message], Message>` — typically wrapping an `LLMProvider`. The summarizer is the user's choice.
- `windowedWithSummary` is the "keep recent N + summary of older" pattern, a common LangChain idiom.
- `custom` is the escape hatch for ad-hoc strategies.

The agent applies `HistoryPolicy` between loading messages from `ChatHistory` and passing them to the provider.

## How the agent consumes memory

```swift
public struct AgentConfig: Sendable {
    public var provider: any LLMProvider
    public var tools: [AnyTool]

    // Optional memory wiring
    public var history: (any ChatHistory)?
    public var checkpointer: (any Checkpointer)?
    public var memoryStore: (any MemoryStore)?

    public var historyPolicy: HistoryPolicy = .lastN(20)
    // ...
}
```

The agent loop:

1. On `run`, loads messages via `history.messages(threadId, ...)`.
2. Applies `historyPolicy`.
3. Calls provider.
4. After each step, appends new messages to `history` and writes a `Checkpoint`.
5. Middleware can use `memoryStore` for RAG injection or fact extraction.

## Memory-aware middleware

```swift
public struct RAGMiddleware: AgentMiddleware {
    let memoryStore: any MemoryStore
    let namespace: [String]
    let topK: Int

    public func beforeStep(_ state: AgentState) async throws -> AgentState {
        let lastUserMessage = state.messages.last(where: { $0.role == .user })?.textContent ?? ""
        let matches = try await memoryStore.recall(
            query: lastUserMessage,
            namespace: namespace,
            topK: topK,
            filter: nil
        )
        var newState = state
        newState.scratchpad["retrieved_context"] = .array(matches.map { .string($0.item.content) })
        return newState
    }

    public func afterStep(_ state: AgentState, event: AgentEvent) async throws -> AgentState {
        return state    // no-op
    }
}
```

The agent core has no special "RAG" code path. RAG is just middleware that uses `MemoryStore`.

## What this layer does NOT include

- Apple-specific storage (SwiftData, sqlite-vec) — those live in `AriaApple`.
- Encryption — opt-in at the implementation layer.
- Sync (iCloud, server-backed) — implementation detail of specific stores.
- Memory eviction policies for the in-memory defaults — they grow unbounded; consumers should use bounded impls in production.

## Testing

In-memory defaults make memory testing trivial:

```swift
let memory = DefaultMemoryStore(
    embedder: HashEmbedder(dimensions: 64),       // deterministic test embedder
    store: InMemoryVectorStore(dimensions: 64)
)
let ref = try await memory.remember(
    MemoryItem(id: UUID().uuidString, content: "User prefers metric units", metadata: [:], createdAt: .now),
    namespace: ["user_42", "preferences"]
)
let matches = try await memory.recall(query: "what units", namespace: ["user_42", "preferences"], topK: 1, filter: nil)
XCTAssertFalse(matches.isEmpty)
```

`HashEmbedder` is provided in `AriaTesting` — a deterministic, fast embedder for tests.

## Future considerations

- **TTL / expiry on memories.** Add `expiresAt: Date?` to `MemoryItem`; impls honor it.
- **Multi-tenant isolation.** Today namespacing is a convention. If isolation must be enforced, consider explicit tenant scoping in the protocol.
- **Vector indexing strategies.** Today the protocol is index-agnostic. If we need to expose IVF/HNSW knobs, they go in implementation-specific config, not the protocol.
- **Cross-store transactions.** A "remember + checkpoint" atomic operation isn't supported. If real consumers need it, introduce a `MemoryTransaction` type.
