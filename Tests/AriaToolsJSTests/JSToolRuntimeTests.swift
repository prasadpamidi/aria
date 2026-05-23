#if canImport(JavaScriptCore)
    import Aria
    import AriaTools
    import Foundation
    import XCTest
    @testable import AriaToolsJS

    /// End-to-end runtime tests — instantiate a JSToolRuntime with a
    /// real `JSContext`, drive `invoke(_:)` with various inputs, and
    /// assert the JS-side `call(input)` produced the expected output.
    ///
    /// Note: these tests bridge across the actual JavaScriptCore engine
    /// so they only run on Apple platforms where JSC is available. On
    /// Linux the whole file compiles to empty and XCTest skips it.
    final class JSToolRuntimeTests: XCTestCase {
        // MARK: Internal

        // MARK: - Synchronous returns

        func testSyncReturnEchoesInput() async throws {
            let bundle = self.bundle(
                capabilities: [],
                main: """
                function call(input) {
                    return { echoed: input.text };
                }
                """
            )
            let runtime = try self.makeRuntime(bundle)
            let result = try await runtime.invokeJSON(["text": "hello"])
            XCTAssertEqual(result["echoed"] as? String, "hello")
        }

        func testIntegerStaysInteger() async throws {
            // Sanity check the round-trip: JS numbers come back as
            // `.integer` when they're whole, `.double` otherwise. We
            // want the agent's JSON contract preserved, not gratuitously
            // coerced to floats.
            let bundle = self.bundle(
                capabilities: [],
                main: "function call(input) { return { n: 42 }; }"
            )
            let runtime = try self.makeRuntime(bundle)
            let result = try await runtime.invokeJSON([:])
            XCTAssertEqual(result["n"] as? Int, 42)
        }

        func testFloatPreserved() async throws {
            let bundle = self.bundle(
                capabilities: [],
                main: "function call(input) { return { n: 3.14 }; }"
            )
            let runtime = try self.makeRuntime(bundle)
            let result = try await runtime.invokeJSON([:])
            XCTAssertEqual(result["n"] as? Double, 3.14)
        }

        func testNestedObjectAndArray() async throws {
            let bundle = self.bundle(
                capabilities: [],
                main: """
                function call(input) {
                    return {
                        items: ["a", "b", "c"],
                        nested: { count: input.count }
                    };
                }
                """
            )
            let runtime = try self.makeRuntime(bundle)
            let result = try await runtime.invokeJSON(["count": 7])
            XCTAssertEqual(result["items"] as? [String], ["a", "b", "c"])
            XCTAssertEqual((result["nested"] as? [String: Any])?["count"] as? Int, 7)
        }

        // MARK: - Async + Promise returns

        func testAsyncPromiseReturn() async throws {
            // `async function` returns a Promise that the runtime must
            // unwrap before resolving the Swift continuation.
            let bundle = self.bundle(
                capabilities: [],
                main: """
                async function call(input) {
                    return { doubled: input.n * 2 };
                }
                """
            )
            let runtime = try self.makeRuntime(bundle)
            let result = try await runtime.invokeJSON(["n": 21])
            XCTAssertEqual(result["doubled"] as? Int, 42)
        }

        // MARK: - Error paths

        func testMissingCallFunctionThrows() async throws {
            let bundle = self.bundle(
                capabilities: [],
                main: "const x = 1;" // no `call` defined
            )
            let runtime = try self.makeRuntime(bundle)
            do {
                _ = try await runtime.invokeJSON([:])
                XCTFail("expected throw")
            } catch JSToolRuntimeError.missingCallFunction {
                // expected
            }
        }

        func testJSThrowSurfaces() async throws {
            let bundle = self.bundle(
                capabilities: [],
                main: """
                function call(input) {
                    throw new Error("boom");
                }
                """
            )
            let runtime = try self.makeRuntime(bundle)
            do {
                _ = try await runtime.invokeJSON([:])
                XCTFail("expected throw")
            } catch let JSToolRuntimeError.callThrew(message) {
                XCTAssertTrue(message.contains("boom"), "got: \(message)")
            }
        }

        func testEvaluationFailureOnLoadThrows() throws {
            let bundle = self.bundle(
                capabilities: [],
                main: "this is not valid javascript;;;"
            )
            XCTAssertThrowsError(try self.makeRuntime(bundle)) { error in
                guard case JSToolRuntimeError.evaluationFailed = error else {
                    XCTFail("unexpected: \(error)")
                    return
                }
            }
        }

        // MARK: - Bridge surface

        func testHTTPCapabilityRoutesThroughInjectedClient() async throws {
            let stub = StubHTTPClient(
                status: 200,
                data: Data(#"{"weather":"sunny"}"#.utf8)
            )
            let bundle = self.bundle(
                capabilities: [.http, .json],
                main: """
                async function call(input) {
                    const r = await Aria.http.get(input.url);
                    return { status: r.status, body: r.body };
                }
                """
            )
            let runtime = try JSToolRuntime(
                bundle: bundle,
                httpClient: stub,
                storage: JSToolStorage(toolId: bundle.id),
                globalName: "Aria"
            )
            let result = try await runtime.invokeJSON(["url": "https://example.com"])
            XCTAssertEqual(result["status"] as? Int, 200)
            XCTAssertEqual(result["body"] as? String, #"{"weather":"sunny"}"#)
        }

        func testUndeclaredCapabilityNotBound() async throws {
            // Tools that don't declare `.http` must literally not have
            // `Aria.http` available — the test confirms calling it
            // surfaces a JS reference error.
            let bundle = self.bundle(
                capabilities: [],
                main: """
                async function call(input) {
                    try {
                        Aria.http.get("https://example.com");
                        return { ok: true };
                    } catch (e) {
                        return { ok: false, error: String(e) };
                    }
                }
                """
            )
            let runtime = try self.makeRuntime(bundle)
            let result = try await runtime.invokeJSON([:])
            XCTAssertEqual(result["ok"] as? Bool, false)
            let errorMessage = (result["error"] as? String) ?? ""
            XCTAssertTrue(
                errorMessage.contains("undefined") || errorMessage.contains("TypeError"),
                "expected reference/type error, got: \(errorMessage)"
            )
        }

        func testStorageRoundTrip() async throws {
            let bundle = self.bundle(
                capabilities: [.storage],
                main: """
                async function call(input) {
                    if (input.action === "write") {
                        Aria.storage.set(input.key, input.value);
                        return { ok: true };
                    }
                    return { value: Aria.storage.get(input.key) };
                }
                """
            )
            let runtime = try self.makeRuntime(bundle)
            _ = try await runtime.invokeJSON([
                "action": "write",
                "key": "fav",
                "value": "blue",
            ])
            let result = try await runtime.invokeJSON([
                "action": "read",
                "key": "fav",
            ])
            XCTAssertEqual(result["value"] as? String, "blue")
            // Clean up so the suite doesn't accumulate state across test runs.
            JSToolStorage(toolId: bundle.id).clearAll()
        }

        // MARK: Private

        // MARK: - Helpers

        private func bundle(capabilities: [JSToolCapability], main: String) -> JSToolBundle {
            JSToolBundle(
                id: "com.test.\(UUID().uuidString)",
                name: "test_tool",
                description: "test",
                version: "1.0.0",
                capabilities: capabilities,
                inputSchema: .object(properties: [:], additionalProperties: true),
                main: main
            )
        }

        private func makeRuntime(_ bundle: JSToolBundle) throws -> JSToolRuntime {
            try JSToolRuntime(
                bundle: bundle,
                httpClient: URLSessionHTTPClient(),
                storage: JSToolStorage(toolId: bundle.id),
                globalName: "Aria"
            )
        }
    }

    // MARK: - JSToolRuntime test convenience

    extension JSToolRuntime {
        /// Decode a dictionary-shaped JS result back into a Foundation
        /// dict for test assertions. Wraps `invoke(_:)` so each test
        /// doesn't repeat the JSONValue ↔ dict conversion plumbing.
        fileprivate func invokeJSON(_ input: [String: Any]) async throws -> [String: Any] {
            let inputJSON = try JSONValueAdapter.encode(input)
            let result = try await self.invoke(inputJSON)
            return try JSONValueAdapter.decodeObject(result)
        }
    }

    // MARK: - JSONValueAdapter

    /// Bridges between Foundation-typed dictionaries (what tests author
    /// against) and Aria's `JSONValue` (what the runtime traffics in).
    /// Lives in the test target so the production code stays focused.
    private enum JSONValueAdapter {
        static func encode(_ value: Any) throws -> JSONValue {
            switch value {
            case let bool as Bool: return .bool(bool)
            case let int as Int: return .integer(Int64(int))
            case let double as Double: return .number(double)
            case let string as String: return .string(string)
            case let array as [Any]: return try .array(array.map(self.encode))
            case let dict as [String: Any]:
                var map: [String: JSONValue] = [:]
                for (k, v) in dict {
                    map[k] = try self.encode(v)
                }
                return .object(map)
            case is NSNull: return .null
            default:
                throw NSError(domain: "JSONValueAdapter", code: 1)
            }
        }

        static func decodeObject(_ value: JSONValue) throws -> [String: Any] {
            guard case let .object(map) = value else {
                throw NSError(domain: "JSONValueAdapter", code: 2)
            }
            var result: [String: Any] = [:]
            for (k, v) in map {
                result[k] = self.decode(v)
            }
            return result
        }

        static func decode(_ value: JSONValue) -> Any {
            switch value {
            case .null: return NSNull()
            case let .bool(b): return b
            case let .integer(i): return Int(i)
            case let .number(d): return d
            case let .string(s): return s
            case let .array(values): return values.map(self.decode)
            case let .object(map):
                var out: [String: Any] = [:]
                for (k, v) in map {
                    out[k] = self.decode(v)
                }
                return out
            }
        }
    }

    // MARK: - StubHTTPClient

    private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
        // MARK: Lifecycle

        init(status: Int, data: Data) {
            self.status = status
            self.data = data
        }

        // MARK: Internal

        let status: Int
        let data: Data

        func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "about:blank")!,
                statusCode: self.status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            return (self.data, response)
        }
    }
#endif
