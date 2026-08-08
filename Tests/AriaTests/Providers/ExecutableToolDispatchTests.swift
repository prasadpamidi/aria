import Foundation
import XCTest
@testable import Aria

// MARK: - ExecutableToolDispatchTests

/// `stream(messages:executableTools:options:)` must be a protocol
/// *requirement*, not an extension member.
///
/// The agent holds providers as `any LLMProvider`, and Swift dispatches
/// protocol-extension members statically — so while this lived in an
/// extension, a conforming type's implementation was never reached and
/// every call silently fell through to the default forwarding form.
///
/// `FoundationModelsProvider` consequently always received an empty
/// tool list and fell back to the full set given at construction,
/// ignoring per-turn tool selection and overflowing a 4,096-token
/// window with 6,042 tokens.
final class ExecutableToolDispatchTests: XCTestCase {
    /// Dispatch through the existential the agent actually uses.
    func testExecutableToolsReachTheProviderThroughAnExistential() async throws {
        let provider = RecordingProvider()
        let erased: any LLMProvider = provider

        let stream = erased.stream(
            messages: [.user("hi")],
            executableTools: [Self.tool(named: "current_time")],
            options: .init()
        )
        for try await _ in stream {}

        XCTAssertTrue(
            provider.sawExecutableVariant,
            "A conforming type's implementation must win over the default"
        )
        XCTAssertEqual(provider.receivedToolNames, ["current_time"])
    }

    /// Providers that don't implement it keep the forwarding default.
    func testDefaultForwardsToTheDefinitionOnlyForm() async throws {
        let provider = DefinitionOnlyProvider()
        let erased: any LLMProvider = provider

        let stream = erased.stream(
            messages: [.user("hi")],
            executableTools: [Self.tool(named: "log_meal")],
            options: .init()
        )
        for try await _ in stream {}

        XCTAssertEqual(provider.receivedDefinitionNames, ["log_meal"])
    }

    // MARK: - Helpers

    private static func tool(named name: String) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: "A tool.",
                inputSchema: .object(properties: [:], required: [])
            ),
            invoke: { _, _ in .null }
        )
    }

    /// Implements the executable variant, as FoundationModels does.
    private final class RecordingProvider: LLMProvider, @unchecked Sendable {
        let capabilities = ProviderCapabilities(modelIdentifier: "recording")
        private(set) var sawExecutableVariant = false
        private(set) var receivedToolNames: [String] = []

        func stream(
            messages _: [Message],
            tools _: [ToolDefinition],
            options _: GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func stream(
            messages _: [Message],
            executableTools: [AnyTool],
            options _: GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            self.sawExecutableVariant = true
            self.receivedToolNames = executableTools.map(\.name)
            return AsyncThrowingStream { $0.finish() }
        }
    }

    /// Implements only the requirement, relying on the default.
    private final class DefinitionOnlyProvider: LLMProvider, @unchecked Sendable {
        let capabilities = ProviderCapabilities(modelIdentifier: "definition-only")
        private(set) var receivedDefinitionNames: [String] = []

        func stream(
            messages _: [Message],
            tools: [ToolDefinition],
            options _: GenerationOptions
        ) -> AsyncThrowingStream<ProviderEvent, any Error> {
            self.receivedDefinitionNames = tools.map(\.name)
            return AsyncThrowingStream { $0.finish() }
        }
    }
}
