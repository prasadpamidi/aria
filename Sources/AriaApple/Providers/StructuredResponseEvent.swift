#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels

    // MARK: - StructuredResponseEvent

    /// Event emitted by `Agent.respond(_:as:)` and
    /// `FoundationModelsProvider.streamStructured(_:as:)` while a typed
    /// `Content` response is being generated. The stream finishes after
    /// `.finish(Content)` is yielded.
    @available(iOS 26.0, macOS 26.0, *)
    public enum StructuredResponseEvent<Content: Generable & Sendable>: Sendable
    where Content.PartiallyGenerated: Sendable {
        /// A partial parse FoundationModels has produced so far. Each
        /// property of `Content.PartiallyGenerated` is optional until
        /// the model has committed to a value, so the UI can render
        /// progressive updates as the model streams.
        case partial(Content.PartiallyGenerated)

        /// A tool call FoundationModels resolved during generation.
        /// Mirrors the regular streaming flow's tool events so consumers
        /// can surface mid-response activity.
        case toolCallExecuted(call: ToolCall, result: ToolExecutionResult)

        /// The final, fully resolved `Content` value, decoded from the
        /// last snapshot's raw `GeneratedContent`.
        case finish(Content)
    }

#endif
