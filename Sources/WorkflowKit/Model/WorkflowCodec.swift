import Foundation

// MARK: - WorkflowCodec

/// Helpers for moving a `Workflow` between its in-memory form and
/// JSON bytes (for GRDB blobs in slice 2, `.workflow.json` file
/// import/export in slice 12, and the AppIntents pass-through in
/// slice 11).
///
/// Centralised so encoder/decoder configuration (date strategy,
/// key ordering, pretty-printing) is one decision rather than a
/// per-call sprinkle. `pretty` mode is opt-in via `forExport:` —
/// in-process round-trips use the compact form to keep the GRDB
/// blob size small.
public enum WorkflowCodec {
    // MARK: Public

    /// In-memory encode. Compact JSON, ISO-8601 dates.
    public static func encode(_ workflow: Workflow) throws -> Data {
        try self.encoder(pretty: false).encode(workflow)
    }

    /// File / share-sheet encode. Pretty-printed JSON with sorted
    /// keys so diffs read cleanly when workflows are checked in to
    /// version control or shared via `.workflow.json` files.
    public static func exportData(_ workflow: Workflow) throws -> Data {
        try self.encoder(pretty: true).encode(workflow)
    }

    public static func decode(_ data: Data) throws -> Workflow {
        try self.decoder().decode(Workflow.self, from: data)
    }

    /// Write a workflow to disk in pretty form. Atomic to avoid
    /// torn writes when sharing via Files / iCloud Drive.
    public static func write(_ workflow: Workflow, to url: URL) throws {
        try self.exportData(workflow).write(to: url, options: .atomic)
    }

    /// Read a workflow from disk. Throws the same decode error as
    /// `decode(_:)` if the file isn't a valid workflow envelope.
    public static func read(from url: URL) throws -> Workflow {
        let data = try Data(contentsOf: url)
        return try Self.decode(data)
    }

    // MARK: Private

    /// Dates encode as Unix-epoch `Double`s (seconds since
    /// 1970). The obvious alternative — ISO-8601 strings — caps
    /// at millisecond precision even with `.withFractionalSeconds`,
    /// but `Date()` returns microsecond-precision values, so a
    /// `Date() → encode → decode` round-trip silently loses
    /// precision and breaks `Equatable`. Storing the raw
    /// `timeIntervalSince1970` keeps the round-trip lossless and
    /// the JSON storage compact. Pretty-export still produces
    /// stable diff output because the float is just one numeric
    /// field per date.
    private static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
