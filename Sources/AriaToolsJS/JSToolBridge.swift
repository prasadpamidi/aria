#if canImport(JavaScriptCore)
    import Aria
    import AriaTools
    import Foundation
    import JavaScriptCore

    #if canImport(UIKit)
        import UIKit
    #endif
    #if canImport(UserNotifications)
        import UserNotifications
    #endif

    // MARK: - JSToolBridgeBuilder

    /// Builds the `Avyra` global inside a freshly-prepared `JSContext`
    /// based on a bundle's declared capabilities. The builder is the
    /// single chokepoint between user JS and the outside world — every
    /// capability the manifest doesn't claim corresponds to a property
    /// we never assign, so the JS body literally cannot reach it.
    ///
    /// Each `bind*` method is a hook a host app can re-implement if it
    /// wants to substitute a different transport (e.g. a vetted HTTP
    /// client, an alternative clipboard backing) without forking the
    /// runtime.
    struct JSToolBridgeBuilder {
        // MARK: Lifecycle

        init(
            bundle: JSToolBundle,
            httpClient: any HTTPClient,
            storage: JSToolStorage
        ) {
            self.bundle = bundle
            self.httpClient = httpClient
            self.storage = storage
        }

        // MARK: Internal

        /// Construct the `Avyra` object and assign it to the JSContext's
        /// global. After this returns, the user JS can reference `Avyra`
        /// at top level.
        func install(into context: JSContext) {
            let avyra: [String: Any] = self.assembleBridge(context: context)
            context.setObject(avyra, forKeyedSubscript: "Avyra" as NSString)
        }

        // MARK: Private

        private let bundle: JSToolBundle
        private let httpClient: any HTTPClient
        private let storage: JSToolStorage

        // MARK: - Promise helper

        /// Wrap an async Swift operation in a JS Promise. Both resolve
        /// and reject are dispatched onto the JSContext's thread so JS
        /// authors can `await` the call without worrying about thread
        /// affinity. The runtime never touches the resolve/reject
        /// closures after one of them has fired.
        ///
        /// The resolve/reject closures are typed `@Sendable` so an
        /// async executor (e.g. our `Task { … }` HTTP path) can safely
        /// capture them — the underlying `JSValue.call` is documented
        /// thread-safe with respect to the JS engine's lock. The
        /// `@unchecked Sendable` envelope around `JSValue` is the
        /// minimum surface needed to bridge the call.
        private static func makePromise(
            in context: JSContext,
            executor: @escaping (
                @Sendable @escaping ([String: Any]) -> Void,
                @Sendable @escaping ([String: Any]) -> Void
            ) -> Void
        ) -> JSValue {
            let promiseConstructor = context.objectForKeyedSubscript("Promise")!
            let contextBox = JSValueBox(value: context)
            let block: @convention(block) (JSValue, JSValue) -> Void = { resolveFn, rejectFn in
                let resolveBox = JSValueBox(value: resolveFn)
                let rejectBox = JSValueBox(value: rejectFn)
                let resolve: @Sendable ([String: Any]) -> Void = { value in
                    resolveBox.value.call(withArguments: [value])
                }
                let reject: @Sendable ([String: Any]) -> Void = { error in
                    let err = contextBox.value.objectForKeyedSubscript("Error")
                        .construct(withArguments: [error["message"] ?? "Tool bridge error"])
                    rejectBox.value.call(withArguments: [err as Any])
                }
                executor(resolve, reject)
            }
            // swiftlint:disable:next force_unwrapping
            return promiseConstructor.construct(withArguments: [unsafeBitCast(block, to: AnyObject.self)])!
        }

        private func assembleBridge(context: JSContext) -> [String: Any] {
            var avyra: [String: Any] = [
                "toolId": self.bundle.id,
                "toolVersion": self.bundle.version,
            ]
            let capabilities = self.bundle.capabilitySet
            if capabilities.contains(.http) {
                avyra["http"] = self.bindHTTP(context: context)
            }
            if capabilities.contains(.json) {
                avyra["json"] = self.bindJSON(context: context)
            }
            if capabilities.contains(.clipboard) {
                avyra["clipboard"] = self.bindClipboard(context: context)
            }
            if capabilities.contains(.share) {
                avyra["share"] = self.bindShare(context: context)
            }
            if capabilities.contains(.notify) {
                avyra["notify"] = self.bindNotify(context: context)
            }
            if capabilities.contains(.storage) {
                avyra["storage"] = self.bindStorage(context: context)
            }
            return avyra
        }

        // MARK: - HTTP

        /// Returns `{ get, post, request }`. Each call returns a Promise
        /// that resolves with `{ status, headers, body, isBinary }`.
        /// JS authors can `await` directly.
        private func bindHTTP(context: JSContext) -> [String: Any] {
            let client = self.httpClient

            let request: @convention(block) (String, [String: Any]?) -> JSValue = { urlString, opts in
                Self.makePromise(in: context) { resolve, reject in
                    guard let url = URL(string: urlString) else {
                        reject(["error": "invalid_url", "message": "Could not parse URL: \(urlString)"])
                        return
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = (opts?["method"] as? String) ?? "GET"
                    if let headers = opts?["headers"] as? [String: String] {
                        for (k, v) in headers {
                            req.setValue(v, forHTTPHeaderField: k)
                        }
                    }
                    if let body = opts?["body"] as? String, !body.isEmpty {
                        req.httpBody = Data(body.utf8)
                    }
                    Task {
                        do {
                            let (data, response) = try await client.perform(req)
                            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                            var headerMap: [String: String] = [:]
                            if let http = response as? HTTPURLResponse {
                                for (k, v) in http.allHeaderFields {
                                    if let key = k as? String, let value = v as? String {
                                        headerMap[key] = value
                                    }
                                }
                            }
                            if let text = String(data: data, encoding: .utf8) {
                                resolve([
                                    "status": status,
                                    "headers": headerMap,
                                    "body": text,
                                    "isBinary": false,
                                ])
                            } else {
                                resolve([
                                    "status": status,
                                    "headers": headerMap,
                                    "body": "<binary: \(data.count) bytes>",
                                    "isBinary": true,
                                ])
                            }
                        } catch {
                            reject(["error": "request_failed", "message": error.localizedDescription])
                        }
                    }
                }
            }

            let get: @convention(block) (String, [String: Any]?) -> JSValue = { urlString, opts in
                var merged = opts ?? [:]
                merged["method"] = "GET"
                return request(urlString, merged)
            }

            let post: @convention(block) (String, Any?, [String: Any]?) -> JSValue = { urlString, body, opts in
                var merged = opts ?? [:]
                merged["method"] = "POST"
                if let body {
                    merged["body"] = body
                }
                return request(urlString, merged)
            }

            return [
                "get": unsafeBitCast(get, to: AnyObject.self),
                "post": unsafeBitCast(post, to: AnyObject.self),
                "request": unsafeBitCast(request, to: AnyObject.self),
            ]
        }

        // MARK: - JSON

        /// JavaScript has `JSON.parse` / `JSON.stringify` natively;
        /// `Avyra.json` exists only as a stable surface so authors who
        /// learn the bridge by reading examples have one consistent
        /// namespace. Delegates straight through to the JS engine.
        private func bindJSON(context: JSContext) -> [String: Any] {
            let parse: @convention(block) (String) -> Any? = { text in
                guard let data = text.data(using: .utf8),
                      let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    return nil
                }
                return value
            }

            let stringify: @convention(block) (Any?) -> String? = { value in
                guard let value else {
                    return "null"
                }
                guard let data = try? JSONSerialization.data(
                    withJSONObject: value,
                    options: [.fragmentsAllowed, .sortedKeys]
                ) else {
                    return nil
                }
                return String(data: data, encoding: .utf8)
            }

            return [
                "parse": unsafeBitCast(parse, to: AnyObject.self),
                "stringify": unsafeBitCast(stringify, to: AnyObject.self),
            ]
        }

        // MARK: - Clipboard

        private func bindClipboard(context _: JSContext) -> [String: Any] {
            #if canImport(UIKit)
                let set: @convention(block) (String) -> Void = { text in
                    Task { @MainActor in
                        UIPasteboard.general.string = text
                    }
                }
                let get: @convention(block) () -> String? = {
                    MainActor.assumeIsolated { UIPasteboard.general.string }
                }
                return [
                    "set": unsafeBitCast(set, to: AnyObject.self),
                    "get": unsafeBitCast(get, to: AnyObject.self),
                ]
            #else
                return [:]
            #endif
        }

        // MARK: - Share

        private func bindShare(context _: JSContext) -> [String: Any] {
            #if canImport(UIKit)
                let present: @convention(block) ([String: Any]) -> Void = { payload in
                    // Pull the Sendable primitives out of the
                    // non-Sendable `[String: Any]` payload BEFORE hopping
                    // to the MainActor — `[String: Any]` itself can't
                    // cross the actor boundary under Swift 6 strict
                    // concurrency.
                    let text = payload["text"] as? String
                    let urlString = payload["url"] as? String
                    Task { @MainActor in
                        var items: [Any] = []
                        if let text {
                            items.append(text)
                        }
                        if let urlString, let url = URL(string: urlString) {
                            items.append(url)
                        }
                        guard !items.isEmpty else {
                            return
                        }
                        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
                        let scenes = UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                        let key = scenes.flatMap(\.windows).first { $0.isKeyWindow }
                        key?.rootViewController?.present(activity, animated: true)
                    }
                }
                return ["present": unsafeBitCast(present, to: AnyObject.self)]
            #else
                return [:]
            #endif
        }

        // MARK: - Notify

        private func bindNotify(context _: JSContext) -> [String: Any] {
            #if canImport(UserNotifications)
                let banner: @convention(block) ([String: Any]) -> Void = { payload in
                    let content = UNMutableNotificationContent()
                    content.title = (payload["title"] as? String) ?? ""
                    content.body = (payload["body"] as? String) ?? ""
                    content.sound = .default
                    let request = UNNotificationRequest(
                        identifier: UUID().uuidString,
                        content: content,
                        trigger: nil
                    )
                    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
                }
                return ["banner": unsafeBitCast(banner, to: AnyObject.self)]
            #else
                return [:]
            #endif
        }

        // MARK: - Storage

        private func bindStorage(context _: JSContext) -> [String: Any] {
            let storage = self.storage
            let set: @convention(block) (String, Any?) -> Void = { key, value in
                storage.set(key: key, value: value)
            }
            let get: @convention(block) (String) -> Any? = { key in
                storage.get(key: key)
            }
            let remove: @convention(block) (String) -> Void = { key in
                storage.delete(key: key)
            }
            return [
                "set": unsafeBitCast(set, to: AnyObject.self),
                "get": unsafeBitCast(get, to: AnyObject.self),
                "delete": unsafeBitCast(remove, to: AnyObject.self),
            ]
        }
    }

    // MARK: - JSValueBox

    /// `JSValue` and `JSContext` aren't declared `Sendable` upstream,
    /// but JavaScriptCore documents them as thread-safe under its own
    /// engine lock. Boxing them with `@unchecked Sendable` lets us
    /// capture them in `@Sendable` closures (async HTTP responses,
    /// background Tasks) without sprinkling unsafe-cast warnings
    /// through every call site.
    private final class JSValueBox<T: AnyObject>: @unchecked Sendable {
        // MARK: Lifecycle

        init(value: T) {
            self.value = value
        }

        // MARK: Internal

        let value: T
    }

    // MARK: - JSToolStorage

    /// Per-tool key-value backing. `UserDefaults` suite namespaced under
    /// the tool id so tools can never read each other's storage and so
    /// uninstalling a tool can wipe its data with one suite remove.
    public final class JSToolStorage: @unchecked Sendable {
        // MARK: Lifecycle

        public init(toolId: String) {
            // Suite name uses a dotted prefix so storage shows up
            // grouped in any UserDefaults inspector.
            self.suite = UserDefaults(suiteName: "avyra.toolsjs.storage.\(toolId)") ?? .standard
        }

        // MARK: Public

        public func set(key: String, value: Any?) {
            self.suite.set(value, forKey: key)
        }

        public func get(key: String) -> Any? {
            self.suite.object(forKey: key)
        }

        public func delete(key: String) {
            self.suite.removeObject(forKey: key)
        }

        /// Nuke every value this tool wrote — invoked when the user
        /// uninstalls the tool from the host app.
        public func clearAll() {
            let dict = self.suite.dictionaryRepresentation()
            for key in dict.keys {
                self.suite.removeObject(forKey: key)
            }
        }

        // MARK: Private

        private let suite: UserDefaults
    }
#endif
