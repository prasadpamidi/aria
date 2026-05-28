import Foundation

// MARK: - ContentBlock

/// One piece of content in a multimodal LLM request. Mirrors the
/// vendor-neutral shape used by Aria's chat surface so the same
/// values can flow from `LLMStep.attachmentBindings` into a
/// provider's `generateMultimodal(...)` call.
///
/// Codable for persistence (`JSONValue` interop) and Sendable for
/// cross-actor handoff during a workflow run.
public enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case image(ImageSource)
    case audio(AudioSource)
    case file(FileSource)

    // MARK: Lifecycle

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = try .text(container.decode(String.self, forKey: .text))
        case "image":
            self = try .image(container.decode(ImageSource.self, forKey: .source))
        case "audio":
            self = try .audio(container.decode(AudioSource.self, forKey: .source))
        case "file":
            self = try .file(container.decode(FileSource.self, forKey: .source))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown content block kind: \(kind)"
            )
        }
    }

    // MARK: Public

    /// Which `ContentModality` this block requires from a provider.
    /// Used by the compiler pre-flight to validate that every
    /// attached block has a matching modality in the bound
    /// provider's `supportedModalities`.
    public var modality: ContentModality {
        switch self {
        case .text: .text
        case .image: .image
        case .audio: .audio
        case .file: .file
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("text", forKey: .kind)
            try container.encode(value, forKey: .text)
        case let .image(source):
            try container.encode("image", forKey: .kind)
            try container.encode(source, forKey: .source)
        case let .audio(source):
            try container.encode("audio", forKey: .kind)
            try container.encode(source, forKey: .source)
        case let .file(source):
            try container.encode("file", forKey: .kind)
            try container.encode(source, forKey: .source)
        }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case source
    }
}

// MARK: - ImageSource

/// Where the bytes for an image content block live. `base64` for
/// inline payloads (camera-captured frames, on-device image data);
/// `url` for remote images the provider fetches. `mimeType` is
/// required for `base64` so providers can construct the right
/// `data:` URI; optional for `url` since the server can sniff.
public enum ImageSource: Codable, Sendable, Equatable {
    case base64(mimeType: String, data: String)
    case url(String, mimeType: String? = nil)

    // MARK: Lifecycle

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "base64":
            let mime = try container.decode(String.self, forKey: .mimeType)
            let data = try container.decode(String.self, forKey: .data)
            self = .base64(mimeType: mime, data: data)
        case "url":
            let url = try container.decode(String.self, forKey: .url)
            let mime = try container.decodeIfPresent(String.self, forKey: .mimeType)
            self = .url(url, mimeType: mime)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown image source kind: \(kind)"
            )
        }
    }

    // MARK: Public

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .base64(mime, data):
            try container.encode("base64", forKey: .kind)
            try container.encode(mime, forKey: .mimeType)
            try container.encode(data, forKey: .data)
        case let .url(url, mime):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(mime, forKey: .mimeType)
        }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case kind, mimeType, data, url
    }
}

// MARK: - AudioSource

public enum AudioSource: Codable, Sendable, Equatable {
    case base64(mimeType: String, data: String)
    case url(String, mimeType: String? = nil)

    // MARK: Lifecycle

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "base64":
            let mime = try container.decode(String.self, forKey: .mimeType)
            let data = try container.decode(String.self, forKey: .data)
            self = .base64(mimeType: mime, data: data)
        case "url":
            let url = try container.decode(String.self, forKey: .url)
            let mime = try container.decodeIfPresent(String.self, forKey: .mimeType)
            self = .url(url, mimeType: mime)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown audio source kind: \(kind)"
            )
        }
    }

    // MARK: Public

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .base64(mime, data):
            try container.encode("base64", forKey: .kind)
            try container.encode(mime, forKey: .mimeType)
            try container.encode(data, forKey: .data)
        case let .url(url, mime):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(mime, forKey: .mimeType)
        }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case kind, mimeType, data, url
    }
}

// MARK: - FileSource

public enum FileSource: Codable, Sendable, Equatable {
    case base64(mimeType: String, data: String, name: String? = nil)
    case url(String, mimeType: String? = nil, name: String? = nil)

    // MARK: Lifecycle

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "base64":
            let mime = try container.decode(String.self, forKey: .mimeType)
            let data = try container.decode(String.self, forKey: .data)
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            self = .base64(mimeType: mime, data: data, name: name)
        case "url":
            let url = try container.decode(String.self, forKey: .url)
            let mime = try container.decodeIfPresent(String.self, forKey: .mimeType)
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            self = .url(url, mimeType: mime, name: name)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown file source kind: \(kind)"
            )
        }
    }

    // MARK: Public

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .base64(mime, data, name):
            try container.encode("base64", forKey: .kind)
            try container.encode(mime, forKey: .mimeType)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(name, forKey: .name)
        case let .url(url, mime, name):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(mime, forKey: .mimeType)
            try container.encodeIfPresent(name, forKey: .name)
        }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case kind, mimeType, data, url, name
    }
}
