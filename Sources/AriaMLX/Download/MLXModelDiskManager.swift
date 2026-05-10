import Foundation

// MARK: - MLXDiskModel

/// One model directory found on disk.
public struct MLXDiskModel: Sendable, Hashable {
    // MARK: Lifecycle

    public init(id: String, directory: URL, bytes: Int64) {
        self.id = id
        self.directory = directory
        self.bytes = bytes
    }

    // MARK: Public

    /// Hugging Face id reconstructed from the directory layout
    /// (`<org>/<name>`).
    public let id: String

    /// Local directory containing the model files.
    public let directory: URL

    /// Total bytes used by all files under `directory`.
    public let bytes: Int64
}

// MARK: - MLXModelDiskManager

/// Walks the on-disk Hugging Face cache, computes per-model sizes,
/// and removes models on demand.
///
/// `swift-huggingface` and `swift-transformers` both put downloaded
/// repositories under `Documents/huggingface/models/<org>/<name>/`
/// (sandboxed) by default. The manager treats that directory as the
/// authoritative cache root. Pass a custom root in `init` for tests.
public struct MLXModelDiskManager: Sendable {
    // MARK: Lifecycle

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot()
    }

    // MARK: Public

    public let root: URL

    /// Default root: `Documents/huggingface/models/`. Created lazily;
    /// missing directories are treated as "no models downloaded yet".
    public static func defaultRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Enumerate every downloaded model. Returns an empty array if
    /// the cache root doesn't exist yet.
    public func list() throws -> [MLXDiskModel] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: self.root.path) else {
            return []
        }
        var results: [MLXDiskModel] = []
        let orgs = try fileManager.contentsOfDirectory(
            at: self.root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for orgURL in orgs where Self.isDirectory(orgURL) {
            let models = try fileManager.contentsOfDirectory(
                at: orgURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for modelURL in models where Self.isDirectory(modelURL) {
                let bytes = Self.directorySize(modelURL)
                let id = "\(orgURL.lastPathComponent)/\(modelURL.lastPathComponent)"
                results.append(MLXDiskModel(id: id, directory: modelURL, bytes: bytes))
            }
        }
        return results.sorted { $0.id < $1.id }
    }

    /// Look up one model by Hugging Face id. Returns `nil` when the
    /// model isn't on disk.
    public func find(id: String) throws -> MLXDiskModel? {
        try self.list().first { $0.id == id }
    }

    /// Remove the on-disk directory for `id`. No-op if absent.
    public func remove(id: String) throws {
        guard let entry = try self.find(id: id) else {
            return
        }
        try FileManager.default.removeItem(at: entry.directory)
    }

    // MARK: Private

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    /// Recursive byte-count using `URLResourceValues.fileSize` on
    /// every regular file under `directory`. Symlinks are followed
    /// the same way the downloader follows them.
    private static func directorySize(_ directory: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
