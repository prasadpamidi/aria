# Layer 2 — Runnable

`Runnable<Input, Output>` is Aria's composability primitive. Anything that takes an input and produces an output (a single value or a stream) can be a `Runnable`. Prompts, model calls, output parsers, retrievers, tools (when adapted), and entire agents all conform.

This layer is borrowed in spirit from LangChain's `Runnable`, but its Swift-native expression is meaningfully different.

## Why this exists

Without a unifying composition primitive, every layer above invents its own. With one, you get:

- Uniform `pipe` composition: `prompt | model | parser`
- Uniform decorators: `withRetry`, `withTimeout`, `withObserver`, `withCache`
- Agents that compose into larger agents (an agent is just a `Runnable`)
- A single mental model for "thing that does work"

## The protocol

```swift
public protocol Runnable<Input, Output>: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    func invoke(_ input: Input, options: RunOptions) async throws -> Output

    func stream(_ input: Input, options: RunOptions)
        -> AsyncThrowingStream<Output, Error>
}
```

Both methods are required by the protocol but have **default implementations in terms of each other**. A concrete type implements whichever is natural; the other comes free.

```swift
extension Runnable {
    public func invoke(_ input: Input, options: RunOptions = .init()) async throws -> Output {
        var last: Output?
        for try await value in stream(input, options: options) {
            last = value
        }
        guard let last else { throw AgentError.providerFailed("stream produced no values", underlying: nil) }
        return last
    }

    public func stream(_ input: Input, options: RunOptions = .init())
        -> AsyncThrowingStream<Output, Error>
    {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let value = try await invoke(input, options: options)
                    continuation.yield(value)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
```

**Design choice:** providing both is non-negotiable. Some `Runnable`s (`PromptTemplate`) naturally produce a single value; some (`LLMProvider` adapter) naturally stream. Forcing every implementation to provide both would be cruel; making either-or work via defaults is the right tradeoff.

## Streaming semantics

A `Runnable<Input, Output>`'s stream emits zero or more `Output` values, then finishes (success or error).

There is no special "delta" type at the Runnable layer — the `Output` itself represents what the consumer wants. For text streaming, `Output` is `String` and each yield is a chunk. For agents, `Output` is `AgentEvent` and each yield is one event.

This is intentional: the meaning of "what streams" is a property of the specific Runnable, not the protocol.

## Combinators

These are extension methods on `Runnable`, returning new `Runnable`s. All are `Sendable`-clean and stream-aware.

### `pipe`

```swift
extension Runnable {
    public func pipe<Next: Runnable>(_ next: Next)
        -> some Runnable<Input, Next.Output>
        where Next.Input == Output
}
```

`a.pipe(b)` calls `a`, then feeds its output to `b`. For streams, `b` is invoked once with the *final* output of `a`'s stream — `pipe` is not "fan out per chunk." If you want per-chunk piping, use `mapStream` (below).

### `map`

```swift
extension Runnable {
    public func map<T: Sendable>(
        _ transform: @Sendable @escaping (Output) async throws -> T
    ) -> some Runnable<Input, T>
}
```

`a.map { ... }` transforms `a`'s output without composing with another `Runnable`. Useful for inline transformations.

### `mapStream`

```swift
extension Runnable {
    public func mapStream<T: Sendable>(
        _ transform: @Sendable @escaping (Output) async throws -> T
    ) -> some Runnable<Input, T>
}
```

Like `map`, but applies per-chunk to streams. Use when each streamed value should be transformed independently (e.g., parsing each token chunk).

### `parallel`

```swift
extension Runnable {
    public func parallel<Other: Runnable>(_ other: Other)
        -> some Runnable<Input, (Output, Other.Output)>
        where Other.Input == Input
}
```

Run two Runnables on the same input concurrently; await both. Useful for fan-out (e.g., embed-and-classify in parallel).

### `withRetry`

```swift
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let backoff: Backoff
    public let retryableErrors: @Sendable (Error) -> Bool
    public enum Backoff: Sendable {
        case constant(Duration)
        case exponential(initial: Duration, multiplier: Double, max: Duration)
    }
}

extension Runnable {
    public func withRetry(_ policy: RetryPolicy) -> some Runnable<Input, Output>
}
```

Retries `invoke` (or restarts `stream`) on retryable errors. Streams that have already yielded values are *not* re-yielded on retry — the consumer sees the new attempt's output cleanly.

### `withTimeout`

```swift
extension Runnable {
    public func withTimeout(_ duration: Duration) -> some Runnable<Input, Output>
}
```

Cancels the underlying work and throws `AgentError.timeout` if duration elapses.

### `withObserver`

```swift
extension Runnable {
    public func withObserver(_ observer: any Observer) -> some Runnable<Input, Output>
}
```

Attaches an observer for this and any nested runs. The observer is added to `RunOptions.observers` for downstream calls.

### `withCache`

```swift
extension Runnable {
    public func withCache(_ cache: any RunCache) -> some Runnable<Input, Output>
        where Input: Hashable, Output: Codable
}
```

Caches results keyed on input. Only available when `Input` is `Hashable` and `Output` is `Codable` — type system guarantees correctness.

## The `Observer` protocol

Observers are how cross-cutting concerns (tracing, metrics, logging) plug into `Runnable` execution.

```swift
public protocol Observer: Sendable {
    func runStart(runId: UUID, parentRunId: UUID?, input: Any, options: RunOptions) async
    func runEnd(runId: UUID, output: Any) async
    func runError(runId: UUID, error: Error) async
    func chunk(runId: UUID, value: Any) async
}

public struct NoopObserver: Observer {
    public init() {}
    public func runStart(...) async {}
    public func runEnd(...) async {}
    public func runError(...) async {}
    public func chunk(...) async {}
}
```

**Design notes:**

- `Any` for input/output/value is unfortunate but necessary — observers are heterogeneous, so they can't have associated types.
- The default observer is `NoopObserver`. No-op by default means observation is opt-in.
- Aria does not ship a tracing platform. `OSLogObserver` lives in `AriaApple` for OS-level logging; consumers can implement their own.

## Composing Runnables: an example

```swift
let prompt = PromptTemplate("Answer briefly: {question}")
let model: any Runnable<[Message], String> = ModelRunnable(provider: foundationModelsProvider)
let parser = StringParser()
let observer = OSLogObserver(category: "qa")

let chain: some Runnable<[String: String], String> =
    prompt
        .pipe(model)
        .pipe(parser)
        .withRetry(.init(maxAttempts: 3, backoff: .exponential(...), retryableErrors: { _ in true }))
        .withTimeout(.seconds(30))
        .withObserver(observer)

let answer = try await chain.invoke(["question": "What's a Runnable?"])
```

The chain is fully typed end-to-end. `Runnable`'s associated types make sure `pipe` only connects compatible shapes; the compiler refuses incompatible compositions.

## What this layer does NOT include

- `LLMProvider` itself (Layer 3 — but a `Runnable` adapter exists in Layer 3)
- `Tool` (Layer 3)
- Memory protocols (Layer 4)
- `Agent` (Layer 5 — agents *conform to* Runnable but are defined in Layer 5)

## Testing

`Runnable` tests use simple inline implementations:

```swift
struct DoubleRunnable: Runnable {
    func invoke(_ input: Int, options: RunOptions) async throws -> Int {
        input * 2
    }
}

func testPipeComposition() async throws {
    let chain = DoubleRunnable().pipe(DoubleRunnable())
    let result = try await chain.invoke(3, options: .init())
    XCTAssertEqual(result, 12)
}
```

All Runnable tests run on Linux.

## Future considerations

- **Batch input.** Some Runnables benefit from processing many inputs at once (embedders, batch predictors). `func batch(_ inputs: [Input]) async throws -> [Output]` could be added with a default implementation. Defer until a concrete need.
- **Configurable parallelism for `parallel`.** Today `parallel(_:)` is binary. A variadic or array-based version (`parallelAll([Runnable])`) is plausible. Defer.
- **Existential `Runnable` collections.** Type erasure (`AnyRunnable<Input, Output>`) is provided when needed but not eagerly. Most uses are concrete or `some Runnable<...>`.
