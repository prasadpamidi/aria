import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - CapabilityValidationTests

/// Pre-flight validation: a step whose declared requirements
/// (modalities, multimodal attachments, retry config) aren't met
/// by the resolved provider must fail loud with a typed
/// `WorkflowEngineError` BEFORE any tokens flow.
@Suite("Capability validation (LLM step pre-flight)")
struct CapabilityValidationTests {
    @Test("Step requiring image modality bound to text-only provider throws providerCapabilityMissing")
    func imageRequirementMissing() async throws {
        let provider = TextOnlyProvider()
        let step = LLMStep(
            promptTemplate: "describe {{photo}}",
            outputBinding: "caption",
            requiredModalities: [.image]
        )
        let workflow = Workflow(id: UUID(), name: "vision-fail", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        await #expect(throws: WorkflowEngineError.self) {
            _ = try await runner.run(workflow)
        }
    }

    @Test("Step with attachmentBindings bound to text-only provider throws (implicit multimodal need)")
    func implicitMultimodalRejected() async throws {
        let provider = TextOnlyProvider()
        let step = LLMStep(
            promptTemplate: "describe {{photo}}",
            outputBinding: "caption",
            attachmentBindings: ["photo"]
            // No `requiredModalities` — but the attachment binding
            // implies SOME non-text modality. Pre-flight should
            // reject before trying to resolve the attachment.
        )
        let workflow = Workflow(id: UUID(), name: "vision-implicit", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        await #expect(throws: WorkflowEngineError.self) {
            _ = try await runner.run(workflow)
        }
    }

    @Test("Step requiring image modality bound to image-capable provider succeeds pre-flight")
    func imageRequirementMet() async throws {
        let provider = ImageProvider(payload: .string("ok"))
        let step = LLMStep(
            promptTemplate: "describe {{photo}}",
            outputBinding: "caption",
            attachmentBindings: ["photo"],
            requiredModalities: [.image]
        )
        let workflow = Workflow(id: UUID(), name: "vision-ok", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        // Should NOT throw at the pre-flight gate. The attachment
        // resolution may still fail (no binding supplied here) —
        // accept either success or a multimodalAttachmentInvalid
        // error, both prove the modality check passed.
        do {
            _ = try await runner.run(workflow, input: [
                "photo": .object([
                    "kind": .string("image"),
                    "source": .object([
                        "kind": .string("base64"),
                        "mimeType": .string("image/jpeg"),
                        "data": .string("Zm9v")
                    ])
                ])
            ])
        } catch let error as WorkflowEngineError {
            if case .providerCapabilityMissing = error {
                Issue.record("Should NOT have thrown providerCapabilityMissing for an image-capable provider")
            }
            // Other errors are acceptable for this test's purpose.
        }
    }

    @Test("RetryPolicy with empty retryOn set fails pre-flight (config typo guard)")
    func emptyRetryOnRejected() async throws {
        let provider = TextOnlyProvider()
        let step = LLMStep(
            promptTemplate: "x",
            outputBinding: "y",
            retryPolicy: RetryPolicy(
                maxAttempts: 3,
                backoff: .none,
                retryOn: [] // ← empty: policy can never fire
            )
        )
        let workflow = Workflow(id: UUID(), name: "empty-retry", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        await #expect(throws: WorkflowEngineError.self) {
            _ = try await runner.run(workflow)
        }
    }

    // MARK: - Helpers

    private func makeRunner(provider: any WorkflowLLMProvider) async throws -> WorkflowRunner {
        let broker = CapabilityBroker(firstPartyCallerPrefix: "test.")
        let compiler = WorkflowCompiler(broker: broker, llmProvider: provider)
        return WorkflowRunner(compiler: compiler)
    }
}

// MARK: - Synthetic providers

private struct TextOnlyProvider: WorkflowLLMProvider {
    var capabilities: WorkflowProviderCapabilities {
        // Default conservative — text-only, no multimodal.
        WorkflowProviderCapabilities()
    }
    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        "should-not-reach"
    }
}

private struct ImageProvider: WorkflowLLMProvider {
    let payload: JSONValue
    var capabilities: WorkflowProviderCapabilities {
        WorkflowProviderCapabilities(
            supportsStructuredOutput: false,
            supportedModalities: [.text, .image]
        )
    }
    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        "ok"
    }
    func generateMultimodal(
        content _: [ContentBlock],
        hint _: ModelFamilyHint,
        maxTokens _: Int?,
        schemaID _: String?
    ) async throws -> JSONValue {
        payload
    }
}
