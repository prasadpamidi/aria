import Aria
import Foundation

// MARK: - JSToolBundle

/// On-disk format for a JS-backed tool — a single `.avyra-tool` JSON
/// file with all the metadata + the JS source as a string field.
/// Picked single-file over a folder because AirDrop / Messages /
/// Files all handle one file cleanly; folder distribution would
/// have meant zipping for sharing.
///
/// **Forward compatibility**: `manifestVersion` lets the loader
/// gracefully reject newer formats it doesn't understand, so older
/// app versions don't silently misinterpret newer bundles.
///
/// Example minimal bundle on disk:
/// ```json
/// {
///   "manifestVersion": 1,
///   "id": "com.example.weather",
///   "name": "weather",
///   "displayName": "Weather",
///   "description": "Look up the current weather for a location.",
///   "version": "1.0.0",
///   "author": "Jane Doe",
///   "capabilities": ["http", "json"],
///   "inputSchema": { "type": "object", "properties": { … }, "required": ["city"] },
///   "main": "async function call(input) { const r = await Avyra.http.get(`https://wttr.in/${input.city}?format=j1`);
/// return Avyra.json.parse(r.body); }"
/// }
/// ```
public struct JSToolBundle: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        manifestVersion: Int = 1,
        id: String,
        name: String,
        displayName: String? = nil,
        description: String,
        version: String,
        author: String? = nil,
        capabilities: [JSToolCapability],
        inputSchema: JSONSchema,
        main: String
    ) {
        self.manifestVersion = manifestVersion
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.version = version
        self.author = author
        self.capabilities = capabilities
        self.inputSchema = inputSchema
        self.main = main
    }

    // MARK: Public

    /// The current supported manifest version. Bumped only when a
    /// non-backwards-compatible field is added/changed.
    public static let currentManifestVersion = 1

    /// Format version this bundle was authored against. The loader
    /// rejects bundles with `manifestVersion > currentManifestVersion`.
    public let manifestVersion: Int

    /// Stable reverse-DNS identifier. Used as the storage namespace
    /// key + collision detection key. Must be unique across all
    /// installed tools.
    public let id: String

    /// Tool name as advertised to the model (snake_case, no spaces).
    /// Forwarded into `ToolDefinition.name`.
    public let name: String

    /// Human-readable name for the install UI. Falls back to `name`
    /// when missing.
    public let displayName: String?

    /// Tool description shown to both the model (in
    /// `ToolDefinition`) and the user (install UI). Should explain
    /// *when* the tool is useful, not just what it does — small
    /// models look at this for the call decision.
    public let description: String

    /// Bundle version. Free-form string; recommended semver
    /// (`MAJOR.MINOR.PATCH`).
    public let version: String

    /// Optional author credit. Surface in install UI; not used at
    /// runtime.
    public let author: String?

    /// Capabilities the bridge will bind for this tool. Anything the
    /// JS body tries to call that isn't covered here will fail with
    /// "undefined is not a function" at runtime, so authoring
    /// effectively forces declaration upfront.
    public let capabilities: [JSToolCapability]

    /// JSON Schema for the tool's input. Forwarded into
    /// `ToolDefinition.inputSchema` so the model gets a typed signature.
    public let inputSchema: JSONSchema

    /// JS source code. Must define `async function call(input)` at
    /// top level — the runtime invokes that function with the
    /// decoded input and awaits the returned value.
    public let main: String

    /// `displayName` with a sensible fallback.
    public var resolvedDisplayName: String {
        self.displayName ?? self.name
    }

    /// `Set<JSToolCapability>` view for membership checks.
    public var capabilitySet: Set<JSToolCapability> {
        Set(self.capabilities)
    }

    /// Read and decode a `.avyra-tool` file from disk.
    public static func load(from url: URL) throws -> JSToolBundle {
        let data = try Data(contentsOf: url)
        return try Self.load(from: data)
    }

    /// Decode an in-memory representation. Verifies manifest
    /// version + required-field shape.
    public static func load(from data: Data) throws -> JSToolBundle {
        let decoder = JSONDecoder()
        let bundle: JSToolBundle
        do {
            bundle = try decoder.decode(JSToolBundle.self, from: data)
        } catch {
            throw JSToolBundleError.malformedJSON(error.localizedDescription)
        }
        if bundle.manifestVersion > Self.currentManifestVersion {
            throw JSToolBundleError.unsupportedManifestVersion(bundle.manifestVersion)
        }
        if bundle.id.isEmpty {
            throw JSToolBundleError.missingField("id")
        }
        if bundle.name.isEmpty {
            throw JSToolBundleError.missingField("name")
        }
        if bundle.main.isEmpty {
            throw JSToolBundleError.missingField("main")
        }
        return bundle
    }

    /// Serialize this bundle back to JSON for export / saving.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - JSToolBundleError

public enum JSToolBundleError: LocalizedError, Equatable {
    case malformedJSON(String)
    case unsupportedManifestVersion(Int)
    case missingField(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .malformedJSON(detail):
            "The tool file isn't valid JSON: \(detail)"
        case let .unsupportedManifestVersion(version):
            "This tool was authored for manifest version \(version), which this app doesn't support yet."
        case let .missingField(name):
            "The tool file is missing the required field \"\(name)\"."
        }
    }
}
