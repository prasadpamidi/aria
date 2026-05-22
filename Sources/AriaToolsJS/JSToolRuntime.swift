#if canImport(JavaScriptCore)
    import Aria
    import AriaTools
    import Foundation
    import JavaScriptCore

    // MARK: - JSToolRuntime

    /// Wraps one tool's `JSContext` plus the bridge object bound for it.
    /// Per-tool — never shared across tools, so a malformed or
    /// long-running tool can't leak state into a sibling's run. The
    /// runtime is reused across multiple `call(...)` invocations of the
    /// same tool to amortize context-creation cost.
    ///
    /// **Thread model**: `JSContext` is documented thread-affine. Every
    /// public method on this type runs on the bridge's serial queue so
    /// JS execution never spans threads. Callers await via the
    /// `AsyncSemaphore`-style continuation in `invoke(_:)`.
    final class JSToolRuntime: @unchecked Sendable {
        // MARK: Lifecycle

        init(
            bundle: JSToolBundle,
            httpClient: any HTTPClient,
            storage: JSToolStorage
        ) throws {
            self.bundle = bundle
            guard let context = JSContext() else {
                throw JSToolRuntimeError.contextUnavailable
            }
            self.context = context

            // Make uncaught JS exceptions surface to Swift instead of
            // silently failing — without this, syntax errors in the
            // tool body would set the result to `undefined` with no
            // signal back.
            context.exceptionHandler = { [weak self] _, exception in
                self?.lastException = exception?.toString()
            }

            // Build the bridge BEFORE evaluating the tool body so the
            // body's top-level code (function declarations, module
            // initialization) can reference `Avyra` if it wants to.
            let builder = JSToolBridgeBuilder(
                bundle: bundle,
                httpClient: httpClient,
                storage: storage
            )
            builder.install(into: context)

            // Install a captured `console` object — JS authors expect
            // `console.log` to work. By default JSContext has no
            // console, so the call would throw. Routing through our
            // log buffer lets the dry-run UI replay output post-hoc
            // (and lets future tooling stream logs from prod runs).
            self.installConsole()

            // JavaScriptCore ships pure ECMAScript — no host
            // environment, so `setTimeout` / `setInterval` are
            // undefined by default. Tools that want delayed work or
            // a "wait, then continue" pattern need them, so we
            // bridge dispatch-source timers as those globals. All
            // timers are cancelled on `shutdown()` so a stuck
            // interval can't outlive the runtime.
            self.installTimers()

            // Evaluate the tool source. The tool is expected to define
            // `async function call(input)` at top level. We don't care
            // about the eval result here — we look up `call` at invoke
            // time so the same runtime can survive a function rebind
            // during incremental tool development.
            context.evaluateScript(bundle.main)
            if let exception = self.lastException {
                throw JSToolRuntimeError.evaluationFailed(exception)
            }
        }

        // MARK: Internal

        /// Run the tool body with the given JSON-encoded input. Returns
        /// the JS function's resolved value, JSON-encoded for handoff
        /// back to the agent.
        func invoke(_ input: JSONValue) async throws -> JSONValue {
            self.lastException = nil

            let inputObject = Self.jsonValueToFoundationObject(input)
            guard let callFn = self.context.objectForKeyedSubscript("call"),
                  callFn.isObject else {
                throw JSToolRuntimeError.missingCallFunction
            }

            return try await withCheckedThrowingContinuation { continuation in
                // Resolve / reject closures that bridge JS Promise
                // settlement back to Swift's async continuation. Both
                // are guarded with a fired-once flag so a misbehaving
                // promise that settles twice doesn't crash the agent
                // with a "continuation resumed twice" precondition.
                let settled = AtomicFlag()
                let resolve: @convention(block) (JSValue?) -> Void = { value in
                    guard settled.tryFire() else {
                        return
                    }
                    let decoded = Self.jsValueToJSONValue(value)
                    continuation.resume(returning: decoded)
                }
                let reject: @convention(block) (JSValue?) -> Void = { value in
                    guard settled.tryFire() else {
                        return
                    }
                    let message = value?.toString() ?? "Tool error"
                    continuation.resume(throwing: JSToolRuntimeError.callRejected(message))
                }
                let resolveFn = JSValue(
                    object: unsafeBitCast(resolve, to: AnyObject.self),
                    in: self.context
                )!
                let rejectFn = JSValue(
                    object: unsafeBitCast(reject, to: AnyObject.self),
                    in: self.context
                )!

                let result = callFn.call(withArguments: [inputObject as Any])
                if let exception = self.lastException {
                    if settled.tryFire() {
                        continuation.resume(throwing: JSToolRuntimeError.callThrew(exception))
                    }
                    return
                }
                // The result is expected to be either a Promise or a
                // direct value. Calling `.then` on a non-thenable would
                // throw, so check first.
                if let result, result.hasProperty("then") {
                    result.invokeMethod("then", withArguments: [resolveFn, rejectFn])
                } else {
                    // Synchronous return — settle immediately.
                    if settled.tryFire() {
                        continuation.resume(returning: Self.jsValueToJSONValue(result))
                    }
                }
            }
        }

        /// Tear down the JSContext. Idempotent. Called when the tool is
        /// uninstalled.
        func shutdown() {
            // `JSContext` doesn't have an explicit close — letting it
            // deallocate is the documented teardown. We just clear our
            // exception handler so any in-flight async exceptions don't
            // try to call back into a deallocated owner.
            self.context.exceptionHandler = nil
            self.cancelAllTimers()
        }

        /// Returns any buffered console messages and clears the
        /// buffer. Called by `JSToolProvider.dryRun` so the
        /// authoring UI can surface logs alongside the call result.
        func consumeLogs() -> [JSToolLogEntry] {
            self.logLock.lock()
            defer { self.logLock.unlock() }
            let entries = self.logEntries
            self.logEntries = []
            return entries
        }

        // MARK: Private

        private let bundle: JSToolBundle
        private let context: JSContext
        private var lastException: String?
        private var logEntries: [JSToolLogEntry] = []
        private let logLock = NSLock()
        private var pendingTimers: [Int: DispatchSourceTimer] = [:]
        private var nextTimerID: Int = 1
        private let timerLock = NSLock()

        /// Render a single `console.log` argument. JS strings show
        /// raw; primitives stringify; objects/arrays go through
        /// `JSON.stringify` for a useful default beyond the
        /// near-useless `[object Object]`.
        private static func formatLogArgument(_ value: JSValue) -> String {
            if value.isString {
                return value.toString() ?? ""
            }
            if value.isUndefined {
                return "undefined"
            }
            if value.isNull {
                return "null"
            }
            if value.isBoolean || value.isNumber {
                return value.toString() ?? ""
            }
            // Use JS-side JSON.stringify so objects/arrays render in
            // a familiar shape. Fall back to `toString` if stringify
            // throws (circular refs, etc.).
            guard let context = value.context,
                  let json = context.objectForKeyedSubscript("JSON"),
                  let stringified = json.invokeMethod("stringify", withArguments: [value]) else {
                return value.toString() ?? "[unprintable]"
            }
            if stringified.isUndefined || stringified.isNull {
                return value.toString() ?? "[unprintable]"
            }
            return stringified.toString() ?? value.toString() ?? "[unprintable]"
        }

        /// Convert a `JSONValue` (Aria's typed JSON enum) into a
        /// Foundation object graph (`NSDictionary` / `NSArray` /
        /// `NSNumber` / `NSString`) that JavaScriptCore understands
        /// natively when assigned to a `JSValue`.
        private static func jsonValueToFoundationObject(_ value: JSONValue) -> Any {
            switch value {
            case .null:
                return NSNull()
            case let .bool(bool):
                return bool
            case let .integer(int):
                return int
            case let .number(double):
                return double
            case let .string(string):
                return string
            case let .array(values):
                return values.map(Self.jsonValueToFoundationObject)
            case let .object(map):
                var result: [String: Any] = [:]
                for (key, val) in map {
                    result[key] = Self.jsonValueToFoundationObject(val)
                }
                return result
            }
        }

        /// Inverse of `jsonValueToFoundationObject`. JavaScriptCore
        /// gives us a `JSValue` which we walk recursively, mapping each
        /// JS type to its `JSONValue` counterpart.
        private static func jsValueToJSONValue(_ value: JSValue?) -> JSONValue {
            guard let value, !value.isUndefined, !value.isNull else {
                return .null
            }
            if value.isBoolean {
                return .bool(value.toBool())
            }
            if value.isNumber {
                // Distinguish integers from floats so the JSON we hand
                // back to the agent doesn't gratuitously coerce
                // 42 → 42.0.
                let double = value.toDouble()
                if double.rounded() == double, abs(double) < Double(Int64.max) {
                    return .integer(Int64(double))
                }
                return .number(double)
            }
            if value.isString {
                return .string(value.toString() ?? "")
            }
            if value.isArray {
                let count = Int(value.objectForKeyedSubscript("length").toUInt32())
                var array: [JSONValue] = []
                array.reserveCapacity(count)
                for i in 0..<count {
                    array.append(self.jsValueToJSONValue(value.objectAtIndexedSubscript(i)))
                }
                return .array(array)
            }
            if value.isObject {
                // Walk own enumerable keys via Object.keys. Skip the
                // `then` callable on Promises etc. — we only get here
                // when invoke() already unwrapped the Promise.
                guard let context = value.context,
                      let keys = context.objectForKeyedSubscript("Object")
                          .invokeMethod("keys", withArguments: [value])
                          .toArray() as? [String] else {
                    return .object([:])
                }
                var map: [String: JSONValue] = [:]
                for key in keys {
                    map[key] = self.jsValueToJSONValue(value.objectForKeyedSubscript(key))
                }
                return .object(map)
            }
            return .null
        }

        /// Wire `console.{log,info,warn,error}` to the runtime's
        /// buffer. Each function captures variadic arguments via
        /// `JSContext.currentArguments()` and stringifies them with
        /// space separation — close enough to the browser console
        /// shape that JS authors will recognise it.
        private func installConsole() {
            let consoleObj = JSValue(newObjectIn: self.context)
            consoleObj?.setObject(
                self.makeConsoleFn(level: .log) as Any,
                forKeyedSubscript: "log" as NSString
            )
            consoleObj?.setObject(
                self.makeConsoleFn(level: .info) as Any,
                forKeyedSubscript: "info" as NSString
            )
            consoleObj?.setObject(
                self.makeConsoleFn(level: .warn) as Any,
                forKeyedSubscript: "warn" as NSString
            )
            consoleObj?.setObject(
                self.makeConsoleFn(level: .error) as Any,
                forKeyedSubscript: "error" as NSString
            )
            self.context.setObject(
                consoleObj as Any,
                forKeyedSubscript: "console" as NSString
            )
        }

        private func makeConsoleFn(level: JSToolLogEntry.Level) -> @convention(block) () -> Void {
            { [weak self] in
                let arguments = JSContext.currentArguments() as? [JSValue] ?? []
                let message = arguments
                    .map { Self.formatLogArgument($0) }
                    .joined(separator: " ")
                self?.appendLog(level: level, message: message)
            }
        }

        private func appendLog(level: JSToolLogEntry.Level, message: String) {
            let entry = JSToolLogEntry(level: level, message: message, timestamp: Date())
            self.logLock.lock()
            self.logEntries.append(entry)
            self.logLock.unlock()
        }

        // MARK: - Timers

        /// Wire `setTimeout` / `setInterval` / `clearTimeout` /
        /// `clearInterval` so JS authors get the browser-shaped
        /// timer surface JavaScriptCore omits. Each function gets a
        /// numeric handle the clear* functions take to cancel.
        private func installTimers() {
            let setTimeoutFn: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, delay in
                self?.scheduleTimer(repeats: false, delayMs: delay, callback: callback) ?? 0
            }
            let setIntervalFn: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, delay in
                self?.scheduleTimer(repeats: true, delayMs: delay, callback: callback) ?? 0
            }
            let clearFn: @convention(block) (Int) -> Void = { [weak self] identifier in
                self?.cancelTimer(id: identifier)
            }
            self.context.setObject(
                setTimeoutFn,
                forKeyedSubscript: "setTimeout" as NSString
            )
            self.context.setObject(
                setIntervalFn,
                forKeyedSubscript: "setInterval" as NSString
            )
            self.context.setObject(
                clearFn,
                forKeyedSubscript: "clearTimeout" as NSString
            )
            self.context.setObject(
                clearFn,
                forKeyedSubscript: "clearInterval" as NSString
            )
        }

        private func scheduleTimer(
            repeats: Bool,
            delayMs: Double,
            callback: JSValue
        ) -> Int {
            self.timerLock.lock()
            let identifier = self.nextTimerID
            self.nextTimerID += 1
            self.timerLock.unlock()

            // Run timer events on the main queue so the JSContext
            // (which is created on main in app use) stays
            // thread-affine. Browser semantics also fire timers on
            // the main runloop, so behaviour matches author
            // expectations.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            let delay = max(delayMs, 0)
            let interval = DispatchTimeInterval.milliseconds(Int(delay))
            if repeats {
                timer.schedule(deadline: .now() + interval, repeating: interval)
            } else {
                timer.schedule(deadline: .now() + interval)
            }
            timer.setEventHandler { [weak self, weak callback] in
                callback?.call(withArguments: [])
                if !repeats {
                    self?.cancelTimer(id: identifier)
                }
            }
            self.timerLock.lock()
            self.pendingTimers[identifier] = timer
            self.timerLock.unlock()
            timer.resume()
            return identifier
        }

        private func cancelTimer(id: Int) {
            self.timerLock.lock()
            let timer = self.pendingTimers.removeValue(forKey: id)
            self.timerLock.unlock()
            timer?.cancel()
        }

        /// Cancel + drop every outstanding timer. Called from
        /// `shutdown()` so a long-running `setInterval` can't
        /// outlive its parent runtime.
        private func cancelAllTimers() {
            self.timerLock.lock()
            let timers = self.pendingTimers.values
            self.pendingTimers.removeAll()
            self.timerLock.unlock()
            for timer in timers {
                timer.cancel()
            }
        }
    }

    // MARK: - AtomicFlag

    /// One-shot fire-once flag for guarding `withCheckedContinuation`
    /// resume sites. Swift's `OSAllocatedUnfairLock` would also work but
    /// `NSLock` is portable and the contention here is microseconds.
    private final class AtomicFlag: @unchecked Sendable {
        // MARK: Internal

        func tryFire() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.fired {
                return false
            }
            self.fired = true
            return true
        }

        // MARK: Private

        private let lock = NSLock()
        private var fired = false
    }

    // MARK: - JSToolRuntimeError

    public enum JSToolRuntimeError: LocalizedError, Equatable {
        case contextUnavailable
        case evaluationFailed(String)
        case missingCallFunction
        case callThrew(String)
        case callRejected(String)

        // MARK: Public

        public var errorDescription: String? {
            switch self {
            case .contextUnavailable:
                "JavaScriptCore could not allocate a context."
            case let .evaluationFailed(message):
                "Tool source threw during load: \(message)"
            case .missingCallFunction:
                "Tool source does not define `async function call(input)` at top level."
            case let .callThrew(message):
                "Tool threw: \(message)"
            case let .callRejected(message):
                "Tool rejected: \(message)"
            }
        }
    }
#endif
