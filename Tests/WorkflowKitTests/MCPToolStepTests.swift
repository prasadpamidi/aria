import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - MCPToolStepTests

/// Coverage for the MCP step's persisted shape + the compiler's
/// wiring to the credential resolver. Network behaviour belongs
/// to `MCPClient` (and lives behind a `URLSession` we'd need to
/// stub) — these tests pin the seams the engine cares about
/// without requiring an MCP server to exist.
struct MCPToolStepTests {
    @Test
    func mcpToolStepRoundTripsThroughJSON() throws {
        let credentialID = UUID()
        let step = MCPToolStep(
            serverURL: "https://mcp.example.com/jsonrpc",
            credentialID: credentialID,
            toolName: "search_docs",
            argsTemplate: ["query": "{{input.q}}", "limit": "10"],
            outputBinding: "results"
        )
        let node = WorkflowNode.mcpTool(step)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(WorkflowNode.self, from: data)
        guard case let .mcpTool(round) = decoded else {
            Issue.record("Round-tripped to wrong variant: \(decoded)")
            return
        }
        #expect(round == step)
    }

    @Test
    func mcpToolStepRoundTripsWithoutCredential() throws {
        // Servers on a private network don't need auth — the
        // `credentialID` is optional. Encoding should still
        // succeed and the decoded copy must surface `nil`.
        let step = MCPToolStep(
            serverURL: "https://internal.tools/mcp",
            credentialID: nil,
            toolName: "ping",
            argsTemplate: [:],
            outputBinding: "pong"
        )
        let data = try JSONEncoder().encode(WorkflowNode.mcpTool(step))
        let decoded = try JSONDecoder().decode(WorkflowNode.self, from: data)
        guard case let .mcpTool(round) = decoded else {
            Issue.record("Round-tripped to wrong variant: \(decoded)")
            return
        }
        #expect(round.credentialID == nil)
    }

    @Test
    func compilerRejectsEmptyServerURLAtRunTime() async throws {
        // Empty server URL is a configuration error the editor
        // could in principle reject up front, but right now an
        // unfilled step can still hit the engine — verify it
        // surfaces a typed `MCPError.invalidServerURL` rather
        // than a generic URL-parse error.
        let step = MCPToolStep(
            serverURL: "",
            toolName: "anything",
            outputBinding: "result"
        )
        do {
            _ = try await WorkflowCompiler.executeMCPTool(
                step: step,
                state: WorkflowState(),
                resolver: nil
            )
            Issue.record("Empty URL should throw")
        } catch let error as MCPError {
            #expect(error == .invalidServerURL(""))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test
    func compilerSurfacesMissingCredentialWhenResolverNil() async throws {
        // Step names a credentialID but the compiler was built
        // without a resolver — the engine surfaces a typed
        // `MCPError.missingCredential` so the user sees which
        // credential id is dangling instead of a silent skip
        // against the server.
        let credentialID = UUID()
        let step = MCPToolStep(
            serverURL: "https://example.com",
            credentialID: credentialID,
            toolName: "test",
            outputBinding: "result"
        )
        do {
            _ = try await WorkflowCompiler.executeMCPTool(
                step: step,
                state: WorkflowState(),
                resolver: nil
            )
            Issue.record("Missing resolver should throw")
        } catch let error as MCPError {
            #expect(error == .missingCredential(credentialID))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test
    func compilerInterpolatesTemplatedServerURLBeforeValidation() async throws {
        // Regression: `serverURL: "{{input.serverURL}}"` is the
        // shape skeleton workflows use to take the URL from an
        // input field. Before this fix, the raw template string
        // was passed straight to `URL(string:)`, which always
        // failed — surfacing `MCPError.invalidServerURL("{{input.
        // serverURL}}")` even when the user had supplied a
        // valid URL in the run sheet. Verify the engine
        // interpolates first, and that the error message
        // (when validation does fail) reflects the resolved
        // value not the original template — so users see what
        // was actually attempted.
        let step = MCPToolStep(
            serverURL: "{{input.serverURL}}",
            toolName: "{{input.toolName}}",
            outputBinding: "result"
        )
        do {
            _ = try await WorkflowCompiler.executeMCPTool(
                step: step,
                state: WorkflowState(bindings: [
                    "input": .object(["serverURL": .string("not a url")]),
                ]),
                resolver: nil
            )
            Issue.record("Invalid resolved URL should throw")
        } catch let error as MCPError {
            // Post-interpolation value, not the raw template,
            // is what surfaces — confirms render() ran before
            // URL(string:) validation.
            #expect(error == .invalidServerURL("not a url"))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test
    func compilerSurfacesMissingCredentialWhenResolverReturnsNil() async throws {
        let credentialID = UUID()
        let step = MCPToolStep(
            serverURL: "https://example.com",
            credentialID: credentialID,
            toolName: "test",
            outputBinding: "result"
        )
        let resolver: MCPCredentialResolver = { _ in nil }
        do {
            _ = try await WorkflowCompiler.executeMCPTool(
                step: step,
                state: WorkflowState(),
                resolver: resolver
            )
            Issue.record("Resolver-returns-nil should throw")
        } catch let error as MCPError {
            #expect(error == .missingCredential(credentialID))
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}
