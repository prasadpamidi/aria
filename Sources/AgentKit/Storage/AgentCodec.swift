import Foundation

// MARK: - AgentCodec

/// Centralised JSON configuration for persisting agent types
/// (`AgentDefinition`, `AgentRunRecord`). One decision for date
/// strategy so encoder/decoder never drift.
///
/// Dates encode as Unix-epoch `Double`s (`.secondsSince1970`) to
/// match `WorkflowCodec` — the model types round to millisecond on
/// init, so the encode→decode round-trip stays lossless and
/// `Equatable` comparisons against a re-decoded copy don't flake on
/// microsecond low-bits.
enum AgentCodec {
    // MARK: Internal

    static func encode(_ value: some Encodable) throws -> Data {
        try self.encoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try self.decoder().decode(type, from: data)
    }

    // MARK: Private

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
