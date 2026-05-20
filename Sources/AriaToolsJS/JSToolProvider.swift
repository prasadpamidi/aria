#if canImport(JavaScriptCore)
    import Aria
    import AriaTools
    import Foundation

    // MARK: - JSToolProvider

    /// Discovers installed `.avyra-tool` bundles, instantiates one
    /// `JSToolRuntime` per bundle, and vends them as `[AnyTool]` to the
    /// agent. Host apps construct one provider and pass `tools()` into
    /// `AgentConfig.tools`.
    ///
    /// **Lifecycle**: tools are loaded once at provider init or on
    /// `install(_:)` / `uninstall(_:)`. Each agent run picks up the
    /// current `tools()` snapshot — re-create the agent (or rebuild
    /// config) after installs/uninstalls to refresh the surface.
    @MainActor
    @Observable
    public final class JSToolProvider {
        // MARK: Lifecycle

        /// - Parameters:
        ///   - bundlesDirectory: Folder containing `.avyra-tool` files.
        ///     Host apps typically pass `Application Support/aria-tools/`.
        ///   - httpClient: Network transport injected into the `Avyra.http`
        ///     bridge. Default `URLSession.shared`; apps that need to
        ///     route through their own auth-aware session pass a custom
        ///     `HTTPClient`.
        public init(
            bundlesDirectory: URL,
            httpClient: any HTTPClient = URLSessionHTTPClient()
        ) {
            self.bundlesDirectory = bundlesDirectory
            self.httpClient = httpClient
            self.reload()
        }

        // MARK: Public

        public struct LoadError: Sendable, Equatable {
            public let url: URL
            public let message: String
        }

        // MARK: - LoadedTool

        public struct LoadedTool: Sendable {
            // MARK: Public

            public let bundle: JSToolBundle
            /// Run the loaded plugin's `call(input)` function with the
            /// given JSON arguments and return its resolved result.
            /// Exposed publicly so app-side adapters (e.g. the
            /// FoundationModels `JSPluginFMTool` bridge) can invoke the
            /// runtime without going through the `AnyTool` wrapper that
            /// `tools()` produces. The runtime itself stays internal.
            public func invoke(_ input: JSONValue) async throws -> JSONValue {
                try await self.runtime.invoke(input)
            }

            // MARK: Internal

            let runtime: JSToolRuntime

            public let sourceURL: URL
        }

        /// Successfully-loaded tool bundles plus their live runtimes.
        public private(set) var loaded: [LoadedTool] = []

        /// Bundles that failed to load. Surface in install/manage UI so
        /// users see why a tool didn't appear.
        public private(set) var errors: [LoadError] = []

        /// Re-scan the bundles directory. Tears down existing runtimes
        /// and rebuilds — calling this every agent construction would
        /// waste cold-start cost, so callers should batch installs/
        /// uninstalls.
        public func reload() {
            for tool in self.loaded {
                tool.runtime.shutdown()
            }
            self.loaded = []
            self.errors = []

            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: self.bundlesDirectory.path, isDirectory: &isDir),
                  isDir.boolValue else {
                return
            }

            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: self.bundlesDirectory,
                    includingPropertiesForKeys: nil
                )
            } catch {
                self.errors.append(LoadError(
                    url: self.bundlesDirectory,
                    message: "Could not read bundles directory: \(error.localizedDescription)"
                ))
                return
            }

            for url in contents where url.pathExtension == "avyra-tool" {
                do {
                    let bundle = try JSToolBundle.load(from: url)
                    let storage = JSToolStorage(toolId: bundle.id)
                    let runtime = try JSToolRuntime(
                        bundle: bundle,
                        httpClient: self.httpClient,
                        storage: storage
                    )
                    self.loaded.append(LoadedTool(
                        bundle: bundle,
                        runtime: runtime,
                        sourceURL: url
                    ))
                } catch {
                    self.errors.append(LoadError(
                        url: url,
                        message: error.localizedDescription
                    ))
                }
            }
        }

        /// Copy a `.avyra-tool` file into the managed directory and
        /// reload. The source URL is read once; the destination filename
        /// is derived from the bundle's `id` so collisions overwrite
        /// rather than accumulate `Foo 2.avyra-tool` siblings.
        @discardableResult
        public func install(from sourceURL: URL) throws -> JSToolBundle {
            let bundle = try JSToolBundle.load(from: sourceURL)
            try FileManager.default.createDirectory(
                at: self.bundlesDirectory,
                withIntermediateDirectories: true
            )
            let destination = self.bundlesDirectory.appendingPathComponent(
                "\(bundle.id).avyra-tool",
                isDirectory: false
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            self.reload()
            return bundle
        }

        /// Remove a previously-installed tool by id. Wipes its storage
        /// suite as well so uninstall doesn't leave orphan keys behind.
        public func uninstall(id: String) {
            if let tool = self.loaded.first(where: { $0.bundle.id == id }) {
                tool.runtime.shutdown()
                try? FileManager.default.removeItem(at: tool.sourceURL)
                JSToolStorage(toolId: id).clearAll()
            }
            self.reload()
        }

        /// Snapshot of all loaded tools as `AnyTool`s, ready to pass
        /// into `AgentConfig.tools`. Each invocation routes through the
        /// per-tool runtime; the `ToolDefinition` is built from the
        /// bundle's manifest (name, description, inputSchema).
        public func tools() -> [AnyTool] {
            self.loaded.map { Self.makeAnyTool(for: $0) }
        }

        // MARK: Private

        private let bundlesDirectory: URL
        private let httpClient: any HTTPClient

        /// Wrap one loaded tool in the closure-based `AnyTool` shape.
        /// Each invocation hands the JSON input straight to the
        /// runtime; errors surface as `AgentError.toolExecutionFailed`
        /// at the agent layer.
        private static func makeAnyTool(for loaded: LoadedTool) -> AnyTool {
            let runtime = loaded.runtime
            let bundle = loaded.bundle
            return AnyTool(
                definition: ToolDefinition(
                    name: bundle.name,
                    description: bundle.description,
                    inputSchema: bundle.inputSchema,
                    outputSchema: nil
                ),
                invoke: { input, _ in
                    try await runtime.invoke(input)
                }
            )
        }
    }
#endif
