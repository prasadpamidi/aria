#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels

    // MARK: - GenerableTool

    /// An `Aria.Tool` whose `Input` is also `FoundationModels.Generable`.
    ///
    /// FoundationModels' tool routing on iOS/macOS 26 only fires for
    /// tools whose `Arguments` is a compile-time `@Generable` type, so
    /// any tool intended for `FoundationModelsProvider` has to declare
    /// its `Input` with `@Generable`. Conformance is additive: a
    /// `GenerableTool` is still a regular `Aria.Tool` and continues to
    /// work against any other provider.
    @available(iOS 26.0, macOS 26.0, *)
    public protocol GenerableTool: Aria.Tool where Input: Generable & Sendable { }

    // MARK: - FoundationModelsToolFactory

    /// A factory the provider invokes per-stream to build a typed
    /// `FoundationModels.Tool` bound to the per-call event-yield
    /// closure. The closure is captured at call time so each stream
    /// gets its own continuation.
    @available(iOS 26.0, macOS 26.0, *)
    public typealias FoundationModelsToolFactory = @Sendable (
        @escaping @Sendable (ProviderEvent) -> Void
    ) -> any FoundationModels.Tool

    // MARK: - FoundationModelsToolKit

    /// Pairs the `AnyTool` (consumed by the agent's portable tool list)
    /// with the `FoundationModelsToolFactory` (consumed by
    /// `FoundationModelsProvider`'s typed-tool list). Built by
    /// `registerFoundationModelsTool` so the call site never has to
    /// spell out the same tool twice.
    @available(iOS 26.0, macOS 26.0, *)
    public struct FoundationModelsToolKit: Sendable {
        // MARK: Lifecycle

        public init(anyTool: AnyTool, factory: @escaping FoundationModelsToolFactory) {
            self.anyTool = anyTool
            self.factory = factory
        }

        // MARK: Public

        public let anyTool: AnyTool
        public let factory: FoundationModelsToolFactory
    }

    // MARK: - registerFoundationModelsTool

    /// Construct a `FoundationModelsToolKit` for `tool`. Pass
    /// `kit.anyTool` to `AgentConfig.tools` and `kit.factory` to
    /// `FoundationModelsProvider(typedTools:)`.
    @available(iOS 26.0, macOS 26.0, *)
    public func registerFoundationModelsTool(
        _ tool: some GenerableTool
    ) -> FoundationModelsToolKit {
        FoundationModelsToolKit(
            anyTool: AnyTool(tool),
            factory: { yield in
                TypedAriaBridgeTool(underlying: tool, yieldEvent: yield)
            }
        )
    }

    // MARK: - TypedAriaBridgeTool

    /// `FoundationModels.Tool` adapter for a `GenerableTool`. The
    /// generic `Arguments = Underlying.Input` exposes the consumer's
    /// `@Generable` struct directly to FM, which is what its tool
    /// router resolves against.
    @available(iOS 26.0, macOS 26.0, *)
    struct TypedAriaBridgeTool<Underlying: GenerableTool>: FoundationModels.Tool {
        // MARK: Lifecycle

        init(
            underlying: Underlying,
            yieldEvent: @escaping @Sendable (ProviderEvent) -> Void
        ) {
            self.underlying = underlying
            self.yieldEvent = yieldEvent
            self.name = Underlying.name
            self.description = Underlying.description
        }

        // MARK: Internal

        typealias Arguments = Underlying.Input
        typealias Output = String

        // Stored — matches the shape FoundationModels' WWDC sample uses
        // (and the probe's NativeProbeTool that is confirmed to fire).
        let name: String
        let description: String

        func call(arguments: Underlying.Input) async throws -> String {
            let callId = UUID().uuidString
            let context = ToolContext(runId: UUID())
            let started = ContinuousClock.now
            // Encode arguments to JSONValue so the synthesized
            // ProviderEvent carries a serializable record. A failed
            // encode is non-fatal — the call still proceeds and the
            // event records an empty arguments object.
            let argsJSON = (try? JSONValue.encode(arguments)) ?? .object([:])
            let toolCall = ToolCall(
                id: callId,
                name: Underlying.name,
                arguments: argsJSON
            )

            do {
                let output = try await self.underlying.call(arguments, context: context)
                let duration = ContinuousClock.now - started
                let outputJSON = try JSONValue.encode(output)
                let result = ToolExecutionResult(
                    output: outputJSON,
                    isError: false,
                    duration: duration
                )
                self.yieldEvent(.toolCallExecuted(call: toolCall, result: result))
                return Self.renderForModel(outputJSON)
            } catch {
                let duration = ContinuousClock.now - started
                let errorMessage = String(describing: error)
                let errorJSON = JSONValue.object(["error": .string(errorMessage)])
                let errorResult = ToolExecutionResult(
                    output: errorJSON,
                    isError: true,
                    duration: duration
                )
                self.yieldEvent(.toolCallExecuted(call: toolCall, result: errorResult))
                return Self.renderForModel(errorJSON)
            }
        }

        // MARK: Private

        private let underlying: Underlying
        private let yieldEvent: @Sendable (ProviderEvent) -> Void

        private static func renderForModel(_ value: JSONValue) -> String {
            guard let data = try? value.canonicalData(),
                  let string = String(bytes: data, encoding: .utf8) else {
                return "{}"
            }
            return string
        }
    }

#endif
