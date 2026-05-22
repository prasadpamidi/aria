#if canImport(JavaScriptCore)
    import Aria
    import Foundation
    import JavaScriptCore

    // MARK: - JavaScriptCoreJSEvaluator

    /// `JSContext`-backed `WorkflowJSEvaluator`. Used by the
    /// `WorkflowCompiler` for `TransformStep` and `BranchStep`
    /// expressions.
    ///
    /// Bindings arrive as native `JSONValue` trees and are
    /// projected into the JS scope as the `b` object — workflow
    /// authors write expressions like:
    ///
    ///     b.events.length > 0           // BranchStep condition
    ///     b.events.map(e => e.title)    // TransformStep result
    ///
    /// The actor owns one `JSContext`. JSContext is thread-affine
    /// — actor isolation gives us serialised access for free, and
    /// the evaluator is cheap to construct so each workflow run
    /// can spin up its own instance if isolation between runs
    /// matters.
    public actor JavaScriptCoreJSEvaluator: WorkflowJSEvaluator {
        // MARK: Lifecycle

        public init() throws {
            guard let context = JSContext() else {
                throw WorkflowEngineError.underlying("Couldn't create JSContext")
            }
            self.context = context
            self.exceptionCapture = ExceptionCapture()
            // Surface uncaught JS errors back to Swift instead of
            // silently producing `undefined` results. The closure
            // can't touch actor-isolated state from its
            // nonisolated context, so the capture is a
            // separately-owned reference type whose access is
            // already serialised by this actor's `run` method.
            let capture = self.exceptionCapture
            context.exceptionHandler = { _, exception in
                capture.value = exception?.toString()
            }
        }

        // MARK: Public

        // MARK: WorkflowJSEvaluator

        public func evaluate(
            expression: String,
            bindings: [String: JSONValue]
        ) async throws -> JSONValue {
            let raw = try self.run(expression: expression, bindings: bindings)
            return Self.jsValueToJSON(raw)
        }

        public func evaluateBool(
            expression: String,
            bindings: [String: JSONValue]
        ) async throws -> Bool {
            let raw = try self.run(expression: expression, bindings: bindings)
            if raw.isBoolean {
                return raw.toBool()
            }
            // Coerce: non-bool truthy values map to true. This
            // matches Shortcuts' "if" behavior and is what most
            // workflow authors expect from `b.events.length`.
            return raw.toBool()
        }

        // MARK: Internal

        /// Tiny reference-type holder for the most-recent JS
        /// exception. The actor's serialised access pattern
        /// guarantees no concurrent mutation; `@unchecked
        /// Sendable` is sound on those grounds.
        final class ExceptionCapture: @unchecked Sendable {
            var value: String?
        }

        // MARK: Private

        private let context: JSContext
        private let exceptionCapture: ExceptionCapture

        /// Recursively translate a JSONValue tree into the
        /// Foundation form JSContext.setObject accepts.
        private static func bindingsToJSObject(_ bindings: [String: JSONValue]) -> [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in bindings {
                result[key] = Self.jsonValueToFoundationObject(value)
            }
            return result
        }

        private static func jsonValueToFoundationObject(_ value: JSONValue) -> Any {
            switch value {
            case .null: return NSNull()
            case let .bool(flag): return flag
            case let .integer(int): return int
            case let .number(double): return double
            case let .string(string): return string
            case let .array(items): return items.map(Self.jsonValueToFoundationObject)
            case let .object(dict):
                var result: [String: Any] = [:]
                for (key, sub) in dict {
                    result[key] = Self.jsonValueToFoundationObject(sub)
                }
                return result
            }
        }

        /// Reverse direction: pull a JSValue back into JSONValue.
        /// Numbers come back as `number` (Double); the workflow
        /// state stays unified on that rep.
        private static func jsValueToJSON(_ value: JSValue) -> JSONValue {
            if value.isUndefined || value.isNull {
                return .null
            }
            if value.isBoolean {
                return .bool(value.toBool())
            }
            if value.isNumber {
                return self.numberJSONValue(value.toDouble())
            }
            if value.isString {
                return .string(value.toString() ?? "")
            }
            if value.isArray {
                return self.jsArrayToJSON(value)
            }
            // Treat anything else as an object.
            guard let dict = value.toDictionary() as? [String: Any] else {
                return .null
            }
            var result: [String: JSONValue] = [:]
            for (key, raw) in dict {
                result[key] = Self.foundationObjectToJSON(raw)
            }
            return .object(result)
        }

        /// Preserve integer-ness when the round-trip is lossless.
        /// Workflow authors expect `b.events.length` to bind as
        /// an int, not 3.0.
        private static func numberJSONValue(_ double: Double) -> JSONValue {
            if double.truncatingRemainder(dividingBy: 1) == 0,
               abs(double) < Double(Int64.max) {
                return .integer(Int64(double))
            }
            return .number(double)
        }

        private static func jsArrayToJSON(_ value: JSValue) -> JSONValue {
            let count = Int(value.objectForKeyedSubscript("length").toUInt32())
            var items: [JSONValue] = []
            items.reserveCapacity(count)
            for index in 0..<count {
                items.append(Self.jsValueToJSON(value.atIndex(index)))
            }
            return .array(items)
        }

        /// Foundation-object → JSONValue. Used when the JS engine
        /// hands back an object via `toDictionary()`.
        private static func foundationObjectToJSON(_ raw: Any) -> JSONValue {
            if raw is NSNull {
                return .null
            }
            if let flag = raw as? Bool {
                return .bool(flag)
            }
            if let number = raw as? NSNumber {
                let double = number.doubleValue
                if double.truncatingRemainder(dividingBy: 1) == 0,
                   abs(double) < Double(Int64.max) {
                    return .integer(Int64(double))
                }
                return .number(double)
            }
            if let string = raw as? String {
                return .string(string)
            }
            if let array = raw as? [Any] {
                return .array(array.map(Self.foundationObjectToJSON))
            }
            if let dict = raw as? [String: Any] {
                var result: [String: JSONValue] = [:]
                for (key, value) in dict {
                    result[key] = Self.foundationObjectToJSON(value)
                }
                return .object(result)
            }
            return .null
        }

        private func run(
            expression: String,
            bindings: [String: JSONValue]
        ) throws -> JSValue {
            self.exceptionCapture.value = nil
            // Install the bindings under `b`. Reset on every call
            // so a stale binding from a prior step's expression
            // can't leak.
            let jsObject = Self.bindingsToJSObject(bindings)
            self.context.setObject(jsObject, forKeyedSubscript: "b" as NSString)

            // Wrap in an IIFE so the expression's `return` can be
            // implicit — workflow authors don't write `return x;`,
            // they write the expression directly.
            let wrapped = "(function(b){return (\(expression));})(b)"
            guard let result = self.context.evaluateScript(wrapped) else {
                throw WorkflowEngineError.underlying(
                    self.exceptionCapture.value ?? "JS expression returned undefined"
                )
            }
            if let exception = self.exceptionCapture.value {
                throw WorkflowEngineError.underlying(exception)
            }
            return result
        }
    }
#endif
