import Aria
import AriaTools
import Foundation

// MARK: - HTTPCapability

/// First-class workflow capability backed by `AriaTools.HTTPTool`.
/// Workflows can now use HTTP as a regular capability step in
/// the editor (`http.fetch`) — JS plugins reach the same surface
/// via their existing `http` capability bridge.
///
/// Why expose this as a Capability when JS plugins already
/// reach HTTP? Workflow steps that don't need a JS sandbox
/// (e.g. "fetch weather, pipe into LLM") shouldn't have to
/// install a plugin just to make a request. The capability is
/// the lighter path.
public actor HTTPCapability: Capability {
    // MARK: Lifecycle

    public init(tool: HTTPTool = HTTPTool()) {
        self.tool = tool
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .http
    }

    public nonisolated var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        switch method {
        case "fetch":
            return try await self.handleFetch(arguments: arguments)
        case "fetchJSON":
            return try await self.handleFetchJSON(arguments: arguments)
        default:
            throw CapabilityError.unknownMethod(capability: .http, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = ["fetch", "fetchJSON"]

    // MARK: Private

    private let tool: HTTPTool

    // MARK: - Arg helpers

    private static func requireStringArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> String {
        guard case let .string(value) = arguments[key] else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string",
                actual: String(describing: arguments[key] ?? .null)
            )
        }
        return value
    }

    private static func optionalStringArg(
        _ key: String,
        from arguments: [String: JSONValue]
    ) -> String? {
        guard case let .string(value) = arguments[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func optionalStringMapArg(
        _ key: String,
        from arguments: [String: JSONValue]
    ) -> [String: String]? {
        guard case let .object(map) = arguments[key] else {
            return nil
        }
        var result: [String: String] = [:]
        for (key, value) in map {
            if case let .string(string) = value {
                result[key] = string
            }
        }
        return result.isEmpty ? nil : result
    }

    private func handleFetch(arguments: [String: JSONValue]) async throws -> JSONValue {
        let url = try Self.requireStringArg("url", from: arguments, method: "fetch")
        let method = Self.optionalStringArg("method", from: arguments) ?? "GET"
        let body = Self.optionalStringArg("body", from: arguments)
        let headers = Self.optionalStringMapArg("headers", from: arguments)
        let output = try await self.tool.call(
            HTTPTool.Input(url: url, method: method, headers: headers, body: body),
            context: ToolContext()
        )
        return .object([
            "status": .integer(Int64(output.status)),
            "body": .string(output.body),
            "isBinary": .bool(output.isBinary),
            "headers": .object(output.headers.mapValues { .string($0) }),
        ])
    }

    private func handleFetchJSON(arguments: [String: JSONValue]) async throws -> JSONValue {
        // Convenience over `fetch` — same call, then parse the
        // body as JSON. Non-JSON responses fail closed rather
        // than handing the model a string when it expected an
        // object.
        let rendered = try await self.handleFetch(arguments: arguments)
        guard case let .object(dict) = rendered,
              case let .string(body) = dict["body"] ?? .null else {
            throw CapabilityError.underlying("fetchJSON: missing string body")
        }
        guard let data = body.data(using: .utf8) else {
            throw CapabilityError.underlying("fetchJSON: body wasn't UTF-8")
        }
        do {
            let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
            var output = dict
            output["json"] = parsed
            return .object(output)
        } catch {
            throw CapabilityError.underlying("fetchJSON: body wasn't valid JSON (\(error.localizedDescription))")
        }
    }
}
