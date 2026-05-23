#if ARIA_MLX
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

        /// Hugging Face id reconstructed from the directory name
        /// (`models--<org>--<name>` → `<org>/<name>`).
        public let id: String

        /// Local directory containing the model files (the
        /// `models--<org>--<name>/` HubCache repo dir).
        public let directory: URL

        /// Total bytes used by all files under `directory` (blobs +
        /// snapshot symlinks; symlinks count as ~0 so this matches the
        /// real on-disk footprint).
        public let bytes: Int64
    }

    // MARK: - MLXModelDiskManager

    /// Walks the on-disk Hugging Face cache, computes per-model sizes,
    /// and removes models on demand.
    ///
    /// `swift-huggingface`'s `HubCache` lays out repos as
    /// `<root>/models--<org>--<name>/{blobs,refs,snapshots}` (matching
    /// the Python `huggingface_hub` cache layout). We pin the root to
    /// `Documents/huggingface/hub/` via
    /// `MLXModelDownloader.defaultCacheDirectory()` so downloads
    /// survive iOS storage pressure (the HubCache default
    /// `Library/Caches/...` is evictable). Pass a custom root in
    /// `init` for tests.
    public struct MLXModelDiskManager: Sendable {
        // MARK: Lifecycle

        public init(root: URL? = nil) {
            self.root = root ?? Self.defaultRoot()
        }

        // MARK: Public

        public let root: URL

        /// Default root: `Documents/huggingface/hub/` (shared with
        /// `MLXModelDownloader.defaultHubClient()`). Created lazily;
        /// missing directories are treated as "no models downloaded yet".
        public static func defaultRoot() -> URL {
            MLXModelDownloader.defaultCacheDirectory()
        }

        /// Enumerate every downloaded model. Returns an empty array if
        /// the cache root doesn't exist yet.
        public func list() throws -> [MLXDiskModel] {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: self.root.path) else {
                return []
            }
            let entries = try fileManager.contentsOfDirectory(
                at: self.root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var results: [MLXDiskModel] = []
            for url in entries where Self.isDirectory(url) {
                guard let id = Self.id(forRepoDirName: url.lastPathComponent) else {
                    continue
                }
                let bytes = Self.directorySize(url)
                results.append(MLXDiskModel(id: id, directory: url, bytes: bytes))
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

        /// Reverse of HubCache's `models--<org>--<name>` naming.
        /// Returns `nil` for any sibling we don't recognise (e.g.
        /// `.metadata`, `.locks`, `datasets--*`, `spaces--*`).
        private static func id(forRepoDirName name: String) -> String? {
            let prefix = "models--"
            guard name.hasPrefix(prefix) else {
                return nil
            }
            let stripped = name.dropFirst(prefix.count)
            // First "--" separates org and repo; replace only that one.
            // (Org slugs can't contain "--" on the Hub.)
            guard let range = stripped.range(of: "--") else {
                return nil
            }
            return stripped.replacingCharacters(in: range, with: "/")
        }

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
#endif
