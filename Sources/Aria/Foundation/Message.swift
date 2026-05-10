import Foundation

// MARK: - Message

/// A unit of conversation between user, assistant, and tools.
///
/// Messages flow through `LLMProvider`s and the agent loop. Content is
/// always represented as an array of `ContentPart`s so multimodal content
/// is first-class from the foundation layer.
public struct Message: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        role: Role,
        content: [ContentPart],
        toolCalls: [ToolCall] = [],
        toolCallId: String? = nil,
        metadata: [String: JSONValue] = [:],
        createdAt: Date = Date()
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.metadata = metadata
        self.createdAt = createdAt
    }

    // MARK: Public

    public enum Role: String, Sendable, Equatable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: [ContentPart]
    public let toolCalls: [ToolCall]
    public let toolCallId: String?
    public let metadata: [String: JSONValue]
    public let createdAt: Date
}

// MARK: - Convenience constructors

extension Message {
    public static func system(_ text: String, metadata: [String: JSONValue] = [:]) -> Message {
        Message(role: .system, content: [.text(text)], metadata: metadata)
    }

    public static func user(_ text: String, metadata: [String: JSONValue] = [:]) -> Message {
        Message(role: .user, content: [.text(text)], metadata: metadata)
    }

    /// Build a user message with one or more images attached. Each
    /// image is appended as a `ContentPart.image(...)` after the
    /// text part. Vision-capable providers (FoundationModels with
    /// vision, MLX VLM models) consume them; text-only providers
    /// drop them silently via `textContent` (which only joins
    /// `.text` parts).
    public static func user(
        _ text: String,
        images: [ImageContent],
        metadata: [String: JSONValue] = [:]
    ) -> Message {
        var content: [ContentPart] = [.text(text)]
        for image in images {
            content.append(.image(image))
        }
        return Message(role: .user, content: content, metadata: metadata)
    }

    public static func assistant(
        _ text: String,
        toolCalls: [ToolCall] = [],
        metadata: [String: JSONValue] = [:]
    ) -> Message {
        Message(
            role: .assistant,
            content: [.text(text)],
            toolCalls: toolCalls,
            metadata: metadata
        )
    }

    public static func tool(
        callId: String,
        content: [ContentPart],
        metadata: [String: JSONValue] = [:]
    ) -> Message {
        Message(
            role: .tool,
            content: content,
            toolCallId: callId,
            metadata: metadata
        )
    }

    public static func tool(
        callId: String,
        text: String,
        metadata: [String: JSONValue] = [:]
    ) -> Message {
        .tool(callId: callId, content: [.text(text)], metadata: metadata)
    }

    /// Concatenates the text content of this message, ignoring non-text parts.
    public var textContent: String {
        self.content.compactMap { part in
            if case let .text(value) = part {
                value
            } else {
                nil
            }
        }
        .joined()
    }
}

// MARK: - ContentPart

/// One element of a `Message`'s content array.
public enum ContentPart: Sendable, Equatable, Codable {
    case text(String)
    case image(ImageContent)
    case audio(AudioContent)
    case toolUse(ToolCall)
    case toolResult(id: String, content: [ContentPart], isError: Bool)
}

// MARK: - ContentPart Codable

extension ContentPart {
    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case image
        case audio
        case toolUse
        case toolResultId
        case toolResultContent
        case toolResultIsError
    }

    private enum Kind: String, Codable {
        case text
        case image
        case audio
        case toolUse
        case toolResult
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = try .text(container.decode(String.self, forKey: .text))
        case .image:
            self = try .image(container.decode(ImageContent.self, forKey: .image))
        case .audio:
            self = try .audio(container.decode(AudioContent.self, forKey: .audio))
        case .toolUse:
            self = try .toolUse(container.decode(ToolCall.self, forKey: .toolUse))
        case .toolResult:
            let id = try container.decode(String.self, forKey: .toolResultId)
            let content = try container.decode([ContentPart].self, forKey: .toolResultContent)
            let isError = try container.decode(Bool.self, forKey: .toolResultIsError)
            self = .toolResult(id: id, content: content, isError: isError)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .text)
        case let .image(value):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(value, forKey: .image)
        case let .audio(value):
            try container.encode(Kind.audio, forKey: .kind)
            try container.encode(value, forKey: .audio)
        case let .toolUse(value):
            try container.encode(Kind.toolUse, forKey: .kind)
            try container.encode(value, forKey: .toolUse)
        case let .toolResult(id, content, isError):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(id, forKey: .toolResultId)
            try container.encode(content, forKey: .toolResultContent)
            try container.encode(isError, forKey: .toolResultIsError)
        }
    }
}

// MARK: - ImageContent

/// An image attached to a message.
public struct ImageContent: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(source: Source, detail: Detail? = nil) {
        self.source = source
        self.detail = detail
    }

    // MARK: Public

    public enum Source: Sendable, Equatable, Codable {
        case data(Data, mimeType: String)
        /// A URL referencing the image. Aria does not fetch URLs in core; the
        /// platform module or consumer handles dereferencing.
        case url(URL)
        /// A platform-managed reference, e.g. a `PHAsset` localIdentifier on
        /// Apple platforms. Resolution is the platform module's responsibility.
        case identifier(String)
    }

    public enum Detail: String, Sendable, Equatable, Codable {
        case low
        case high
        case auto
    }

    public let source: Source
    public let detail: Detail?
}

// MARK: - AudioContent

/// An audio attachment on a message.
public struct AudioContent: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(source: ImageContent.Source, duration: TimeInterval? = nil) {
        self.source = source
        self.duration = duration
    }

    // MARK: Public

    public let source: ImageContent.Source
    public let duration: TimeInterval?
}
