import Foundation

// MARK: - JSONValue

/// A typed representation of an arbitrary JSON value.
///
/// `JSONValue` is the universal exchange format for tool call arguments,
/// tool results, and user-supplied metadata throughout Aria. Using a
/// closed enum (rather than `Any` or `[String: Any]`) preserves type
/// safety across Sendable boundaries.
public indirect enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Conveniences

extension JSONValue {
    /// Encodes any `Encodable` value into a `JSONValue` via `JSONEncoder`.
    public static func encode(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this `JSONValue` into a `Decodable` type via `JSONDecoder`.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    /// Serializes this value to canonical JSON bytes (sorted keys).
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Returns the underlying string if this value is `.string`.
    public var stringValue: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    /// Returns the underlying integer if this value is `.integer`.
    public var integerValue: Int64? {
        if case let .integer(value) = self {
            value
        } else {
            nil
        }
    }

    /// Returns the underlying number (or integer coerced to Double).
    public var numberValue: Double? {
        switch self {
        case let .number(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }

    /// Returns the underlying bool if this value is `.bool`.
    public var boolValue: Bool? {
        if case let .bool(value) = self {
            value
        } else {
            nil
        }
    }

    /// Returns the underlying array if this value is `.array`, else `nil`.
    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            value
        } else {
            nil
        }
    }

    /// Returns the underlying object if this value is `.object`, else `nil`.
    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }
}

// MARK: Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue cannot be decoded from this container"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

// MARK: ExpressibleByNilLiteral

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

// MARK: ExpressibleByBooleanLiteral

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

// MARK: ExpressibleByIntegerLiteral

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) {
        self = .integer(value)
    }
}

// MARK: ExpressibleByFloatLiteral

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

// MARK: ExpressibleByStringLiteral

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

// MARK: ExpressibleByArrayLiteral

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

// MARK: ExpressibleByDictionaryLiteral

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
