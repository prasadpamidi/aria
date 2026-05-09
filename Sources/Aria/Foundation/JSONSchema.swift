import Foundation

// MARK: - JSONSchema

/// A structured description of a JSON value's shape, used for tool input
/// and output schemas.
///
/// `JSONSchema` encodes to and decodes from a subset of the JSON Schema
/// specification. Tool definitions emit their input schema via this type
/// when describing themselves to an `LLMProvider`.
public indirect enum JSONSchema: Sendable, Equatable {
    case string(description: String? = nil, enumValues: [String]? = nil)
    case number(description: String? = nil)
    case integer(description: String? = nil)
    case boolean(description: String? = nil)
    case array(items: JSONSchema, description: String? = nil)
    case object(
        properties: [String: JSONSchema],
        required: [String] = [],
        description: String? = nil,
        additionalProperties: Bool = false
    )
    case oneOf([JSONSchema])
    case anyOf([JSONSchema])
    case allOf([JSONSchema])
    case null
}

// MARK: Codable

extension JSONSchema: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
        case properties
        case required
        case additionalProperties
        case oneOf
        case anyOf
        case allOf
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let composed = try Self.decodeComposedSchema(from: container) {
            self = composed
            return
        }
        self = try Self.decodeTypedSchema(from: container)
    }

    private static func decodeComposedSchema(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> JSONSchema? {
        if let schemas = try container.decodeIfPresent([JSONSchema].self, forKey: .oneOf) {
            return .oneOf(schemas)
        }
        if let schemas = try container.decodeIfPresent([JSONSchema].self, forKey: .anyOf) {
            return .anyOf(schemas)
        }
        if let schemas = try container.decodeIfPresent([JSONSchema].self, forKey: .allOf) {
            return .allOf(schemas)
        }
        return nil
    }

    private static func decodeTypedSchema(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> JSONSchema {
        let type = try container.decode(String.self, forKey: .type)
        let description = try container.decodeIfPresent(String.self, forKey: .description)

        switch type {
        case "string":
            let enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
            return .string(description: description, enumValues: enumValues)
        case "number":
            return .number(description: description)
        case "integer":
            return .integer(description: description)
        case "boolean":
            return .boolean(description: description)
        case "null":
            return .null
        case "array":
            let items = try container.decode(JSONSchema.self, forKey: .items)
            return .array(items: items, description: description)
        case "object":
            return try Self.decodeObjectSchema(from: container, description: description)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown JSON Schema type: \(type)"
            )
        }
    }

    private static func decodeObjectSchema(
        from container: KeyedDecodingContainer<CodingKeys>,
        description: String?
    ) throws -> JSONSchema {
        let properties = try container.decodeIfPresent(
            [String: JSONSchema].self,
            forKey: .properties
        ) ?? [:]
        let required = try container.decodeIfPresent([String].self, forKey: .required) ?? []
        let additional = try container.decodeIfPresent(
            Bool.self,
            forKey: .additionalProperties
        ) ?? false
        return .object(
            properties: properties,
            required: required,
            description: description,
            additionalProperties: additional
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .string(description, enumValues):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(enumValues, forKey: .enumValues)

        case let .number(description):
            try container.encode("number", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .integer(description):
            try container.encode("integer", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case let .boolean(description):
            try container.encode("boolean", forKey: .type)
            try container.encodeIfPresent(description, forKey: .description)

        case .null:
            try container.encode("null", forKey: .type)

        case let .array(items, description):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encodeIfPresent(description, forKey: .description)

        case let .object(properties, required, description, additional):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            if !required.isEmpty {
                try container.encode(required, forKey: .required)
            }
            try container.encodeIfPresent(description, forKey: .description)
            try container.encode(additional, forKey: .additionalProperties)

        case let .oneOf(schemas):
            try container.encode(schemas, forKey: .oneOf)

        case let .anyOf(schemas):
            try container.encode(schemas, forKey: .anyOf)

        case let .allOf(schemas):
            try container.encode(schemas, forKey: .allOf)
        }
    }
}

// MARK: - Conveniences

extension JSONSchema {
    /// Encodes this schema to a `JSONValue` matching JSON Schema's wire format.
    public func toJSONValue() throws -> JSONValue {
        try JSONValue.encode(self)
    }
}
