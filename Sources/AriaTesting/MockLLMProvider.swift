import Aria
import Foundation

// MARK: - MockLLMProvider

/// A scripted `LLMProvider` for tests.
///
/// `MockLLMProvider` emits the next scripted scene each time `stream` is
/// called. Each scene is a list of `ProviderEvent`s; consecutive `stream`
/// calls walk through scenes in order. When scenes are exhausted, the
/// stream throws `MockLLMProviderError.outOfScenes`.
///
/// The provider also records every call (messages, tools, options) so
/// tests can assert on what the agent actually sent the model.
public final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    // MARK: Lifecycle

    public init(
        scenes: [Scene] = [],
        capabilities: ProviderCapabilities = .mockDefault
    ) {
        self.capabilities = capabilities
        self.storage.scenes = scenes
    }

    // MARK: Public

    public struct Scene: Sendable {
        // MARK: Lifecycle

        public init(_ events: [ProviderEvent]) {
            self.events = events
        }

        public init(_ events: ProviderEvent...) {
            self.events = events
        }

        // MARK: Public

        public let events: [ProviderEvent]
    }

    public struct Invocation: Sendable {
        public let messages: [Message]
        public let tools: [ToolDefinition]
        public let options: GenerationOptions
    }

    public let capabilities: ProviderCapabilities

    /// All recorded invocations, in call order.
    public var invocations: [Invocation] {
        self.storage.snapshot()
    }

    /// The number of scenes still queued.
    public var remainingScenes: Int {
        self.storage.remaining
    }

    public func stream(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ProviderEvent, any Error> {
        let invocation = Invocation(messages: messages, tools: tools, options: options)
        let scene = self.storage.consumeNextScene()
        self.storage.recordInvocation(invocation)

        return AsyncThrowingStream { continuation in
            guard let scene else {
                continuation.finish(throwing: MockLLMProviderError.outOfScenes)
                return
            }
            for event in scene.events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    /// Append a scene the next call to `stream` will replay.
    public func enqueue(_ scene: Scene) {
        self.storage.enqueue(scene)
    }

    // MARK: Private

    private let storage = Storage()
}

// MARK: MockLLMProvider.Storage

extension MockLLMProvider {
    /// Internal mutable state, guarded by `NSLock`.
    ///
    /// `MockLLMProvider` is exposed as a class so tests can hand a single
    /// instance to the agent and later inspect `invocations`. We could use
    /// an `actor` here, but the recording surface is sync (so test
    /// assertions read naturally), and `stream` itself is non-async, so
    /// an actor would force an awkward bridge.
    private final class Storage: @unchecked Sendable {
        // MARK: Internal

        var scenes: [Scene] {
            get { self.lock.withLock { self._scenes } }
            set { self.lock.withLock { self._scenes = newValue } }
        }

        var remaining: Int {
            self.lock.withLock { self._scenes.count }
        }

        func consumeNextScene() -> Scene? {
            self.lock.withLock {
                guard !self._scenes.isEmpty else {
                    return nil
                }
                return self._scenes.removeFirst()
            }
        }

        func recordInvocation(_ invocation: Invocation) {
            self.lock.withLock { self._invocations.append(invocation) }
        }

        func enqueue(_ scene: Scene) {
            self.lock.withLock { self._scenes.append(scene) }
        }

        func snapshot() -> [Invocation] {
            self.lock.withLock { self._invocations }
        }

        // MARK: Private

        private let lock = NSLock()
        private var _scenes: [Scene] = []
        private var _invocations: [Invocation] = []
    }
}

// MARK: - MockLLMProviderError

public enum MockLLMProviderError: Error, Sendable, Equatable {
    case outOfScenes
}

// MARK: - Capabilities convenience

extension ProviderCapabilities {
    public static let mockDefault = ProviderCapabilities(
        modelIdentifier: "mock",
        supportsStreaming: true,
        supportsToolUse: true,
        supportsParallelToolCalls: true,
        supportsVision: false,
        supportsAudio: false,
        supportsStructuredOutput: true,
        supportsSystemPrompt: true,
        maxContextTokens: 4096
    )
}

// MARK: - Scene builders

extension MockLLMProvider.Scene {
    /// Convenience: a scene that emits a single text response and stops.
    public static func text(
        _ value: String,
        finishReason: FinishReason = .endTurn,
        messageId: String = UUID().uuidString
    ) -> MockLLMProvider.Scene {
        MockLLMProvider.Scene([
            .messageStart(messageId: messageId),
            .textDelta(value),
            .messageStop(finishReason)
        ])
    }

    /// Convenience: a scene that emits a tool call and stops with `.toolUse`.
    public static func toolCall(
        id: String,
        name: String,
        arguments: JSONValue,
        messageId: String = UUID().uuidString
    ) -> MockLLMProvider.Scene {
        MockLLMProvider.Scene([
            .messageStart(messageId: messageId),
            .toolCallStart(ToolCall(id: id, name: name, arguments: arguments)),
            .toolCallEnd(id: id),
            .messageStop(.toolUse)
        ])
    }
}
