import Aria
import AriaApple
import AriaTesting
import CoreAILanguageModels
import Foundation
import FoundationModels
import XCTest

@available(iOS 27.0, *)
@Generable
private struct ProofStructuredResponse {
    @Guide(description: "A short confirmation status")
    var status: String

    @Guide(description: "A short diagnostic detail")
    var detail: String
}

@available(iOS 27.0, *)
final class CoreAIProofTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["COREAI_ARIA_PROOF"] == "1",
            "Set COREAI_ARIA_PROOF=1 to run the physical-device proof"
        )

        let resources = try XCTUnwrap(
            Bundle.module.url(
                forResource: "Qwen3-0.6B",
                withExtension: nil,
                subdirectory: "Resources"
            ),
            "Export Qwen3-0.6B and copy it into the proof Resources directory"
        )
        let model = try await CoreAILanguageModel(resourcesAt: resources, mode: .eager)
        self.model = model
        self.capabilities = ProviderCapabilities(
            modelIdentifier: "coreai.qwen3-0.6b",
            supportsToolUse: model.capabilities.contains(.toolCalling),
            supportsStructuredOutput: model.capabilities.contains(.guidedGeneration)
        )
        self.toolKit = registerFoundationModelsTool(ProofTool())
    }

    private var model: CoreAILanguageModel?
    private var capabilities: ProviderCapabilities?
    private var toolKit: FoundationModelsToolKit?

    private func provider(includeProofTool: Bool = false) throws -> FoundationModelsProvider {
        let model = try XCTUnwrap(self.model)
        let capabilities = try XCTUnwrap(self.capabilities)
        let toolKit = try XCTUnwrap(self.toolKit)
        return FoundationModelsProvider(
            model: model,
            defaultInstructions: "Follow the diagnostic request exactly and answer concisely.",
            capabilities: capabilities,
            typedTools: includeProofTool ? [toolKit.factory] : []
        )
    }

    private func printTiming(_ label: String, since start: ContinuousClock.Instant) {
        print("CoreAIProof \(label): \(ContinuousClock.now - start)")
    }
}

@available(iOS 27.0, *)
extension CoreAIProofTests {
    func testTextStreamsThroughAria() async throws {
        let started = ContinuousClock.now
        defer { self.printTiming("text", since: started) }

        var sawStart = false
        var text = ""
        var sawStop = false
        for try await event in try self.provider().stream(
            messages: [.user("Reply with one short sentence confirming this Core AI request.")],
            tools: [],
            options: GenerationOptions(maxTokens: 64)
        ) {
            switch event {
            case .messageStart:
                sawStart = true
            case let .textDelta(delta):
                text += delta
            case .messageStop:
                sawStop = true
            default:
                break
            }
        }

        XCTAssertTrue(sawStart, "Expected Aria's provider start event")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(sawStop, "Expected Aria's provider stop event")
    }

    func testStructuredOutputThroughAria() async throws {
        let started = ContinuousClock.now
        defer { self.printTiming("structured", since: started) }

        var sawPartial = false
        var final: ProofStructuredResponse?
        for try await event in try self.provider().streamStructured(
            messages: [.user("Return a status and detail confirming the Core AI Aria proof.")],
            as: ProofStructuredResponse.self
        ) {
            switch event {
            case .partial:
                sawPartial = true
            case let .finish(content):
                final = content
            case .toolCallExecuted:
                break
            }
        }

        XCTAssertTrue(sawPartial, "Expected at least one partial structured value")
        let output = try XCTUnwrap(final)
        XCTAssertFalse(output.status.isEmpty)
        XCTAssertFalse(output.detail.isEmpty)
    }

    func testToolExecutionThroughAria() async throws {
        let started = ContinuousClock.now
        defer { self.printTiming("tool", since: started) }

        var output: ProofToolOutput?
        let toolKit = try XCTUnwrap(self.toolKit)
        for try await event in try self.provider(includeProofTool: true).stream(
            messages: [
                .user(
                    "Call coreai_aria_proof exactly once with request device_integration, "
                        + "then report the returned marker."
                ),
            ],
            executableTools: [toolKit.anyTool],
            options: GenerationOptions(maxTokens: 128)
        ) {
            guard case let .toolCallExecuted(call, result) = event,
                  call.name == ProofTool.name else {
                continue
            }
            output = try result.output.decode(ProofToolOutput.self)
        }

        XCTAssertEqual(output?.marker, "COREAI_ARIA_TOOL_OK")
    }

    func testTaskEvalRecordsDiagnosticResult() async throws {
        let started = ContinuousClock.now
        defer { self.printTiming("task-eval", since: started) }

        let model = try XCTUnwrap(self.model)
        let capabilities = try XCTUnwrap(self.capabilities)
        let toolKit = try XCTUnwrap(self.toolKit)
        let testCase = TaskCase(
            query: "Call coreai_aria_proof once and report the returned marker.",
            tools: [toolKit.anyTool],
            expectedTool: ProofTool.name,
            mustContain: ["COREAI_ARIA_TOOL_OK"],
            note: "One-trial integration diagnostic; semantic misses are recorded, not gated."
        )
        let report = await TaskEval(cases: [testCase], trials: 1).run(
            label: "Core AI through Aria"
        ) { testCase in
            Agent(config: AgentConfig(
                provider: FoundationModelsProvider(
                    model: model,
                    defaultInstructions: "Use the requested diagnostic tool and report its result.",
                    capabilities: capabilities,
                    typedTools: [toolKit.factory]
                ),
                tools: testCase.tools,
                systemPrompt: "Report only results returned by the diagnostic tool."
            ))
        }

        print("\n\(report.summary())\n")
        XCTAssertEqual(report.outcomes.count, 1)
        XCTAssertNil(
            report.outcomes.first?.error,
            "The diagnostic records semantic misses but rejects infrastructure errors"
        )
    }
}
