import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - WorkflowRunner020Tests

/// End-to-end integration tests for the 0.2.0 runner additions —
/// retry, timeout, multimodal dispatch, streaming, SubAgent. Each
/// scenario uses a synthetic `WorkflowLLMProvider` so behaviour can
/// be asserted deterministically without spinning up FoundationModels.
@Suite("WorkflowRunner 0.2.0")
struct WorkflowRunner020Tests {
    // MARK: - Retry path

    @Test("RetryPolicy retries on decode failure and succeeds on second attempt")
    func retriesOnDecodeFailureUntilSuccess() async throws {
        let provider = FlakyProvider(
            failAttempts: 1, // first attempt throws
            successPayload: .object(["text": .string("ok")])
        )
        let step = LLMStep(
            promptTemplate: "ignored",
            outputBinding: "out",
            structuredOutputSchema: "x",
            retryPolicy: RetryPolicy(
                maxAttempts: 3,
                backoff: .none,
                retryOn: [.decodeFailure]
            )
        )
        let workflow = Workflow(
            id: UUID(),
            name: "retry-test",
            nodes: [.llm(step)]
        )
        let runner = try await makeRunner(provider: provider)
        _ = try await runner.run(workflow)
        let attempts = await provider.attemptCount
        #expect(attempts == 2, "Expected 1 failure + 1 success = 2 attempts")
    }

    @Test("RetryPolicy exhausted throws the last error")
    func retryExhaustedPropagates() async throws {
        let provider = FlakyProvider(
            failAttempts: 5, // always fail
            successPayload: .null
        )
        let step = LLMStep(
            promptTemplate: "ignored",
            outputBinding: "out",
            structuredOutputSchema: "x",
            retryPolicy: RetryPolicy(maxAttempts: 2, backoff: .none, retryOn: [.decodeFailure])
        )
        let workflow = Workflow(id: UUID(), name: "retry-fail", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        await #expect(throws: WorkflowEngineError.self) {
            _ = try await runner.run(workflow)
        }
        let attempts = await provider.attemptCount
        #expect(attempts == 2)
    }

    // MARK: - Timeout path

    @Test("Timeout fires when generate runs longer than the per-step budget")
    func timeoutFires() async throws {
        let provider = SleepyProvider(sleepDuration: .seconds(5))
        let step = LLMStep(
            promptTemplate: "ignored",
            outputBinding: "out",
            timeout: .milliseconds(100)
        )
        let workflow = Workflow(id: UUID(), name: "timeout-test", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        await #expect(throws: WorkflowEngineError.self) {
            _ = try await runner.run(workflow)
        }
    }

    // MARK: - Streaming path

    @Test("Streaming emits stepPartial events when provider + caller both opt in")
    func streamingEmitsPartials() async throws {
        let provider = StreamingProvider(
            snapshots: [
                .object(["text": .string("Hi")]),
                .object(["text": .string("Hi there")]),
                .object(["text": .string("Hi there, ready?")])
            ]
        )
        let step = LLMStep(
            promptTemplate: "ignored",
            outputBinding: "msg",
            structuredOutputSchema: "x"
        )
        let workflow = Workflow(id: UUID(), name: "stream-test", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        var partials: [JSONValue] = []
        for try await event in runner.runStreaming(workflow) {
            if case let .stepPartial(_, _, snapshot) = event {
                partials.append(snapshot)
            }
        }
        #expect(partials.count == 3, "Expected 3 streamed snapshots")
    }

    @Test("Non-streaming provider degrades to one terminal yield via default impl")
    func nonStreamingProviderDegradesToOneYield() async throws {
        // ConstantStructuredProvider doesn't override streamStructured,
        // so the default protocol extension wraps generateStructured
        // as a single yield.
        let provider = ConstantStructuredProvider(
            payload: .object(["text": .string("done")])
        )
        let step = LLMStep(
            promptTemplate: "ignored",
            outputBinding: "out",
            structuredOutputSchema: "x"
        )
        let workflow = Workflow(id: UUID(), name: "no-stream", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        var partials = 0
        var completed = 0
        for try await event in runner.runStreaming(workflow) {
            switch event {
            case .stepPartial: partials += 1
            case .stepCompleted: completed += 1
            default: break
            }
        }
        // capabilities.supportsStreamingStructured = false (default) →
        // executor does NOT enter the streaming branch, so no
        // stepPartial events fire. The step still completes.
        #expect(partials == 0)
        #expect(completed == 1)
    }

    // MARK: - Multimodal path

    @Test("LLMStep with attachmentBindings routes through generateMultimodal")
    func attachmentBindingsRouteThroughMultimodal() async throws {
        let provider = RecordingMultimodalProvider(
            payload: .object(["text": .string("a green apple")])
        )
        let step = LLMStep(
            promptTemplate: "What is in this image?",
            outputBinding: "caption",
            attachmentBindings: ["photo"]
        )
        let workflow = Workflow(id: UUID(), name: "vision", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        _ = try await runner.run(
            workflow,
            input: ["photo": .object([
                "kind": .string("image"),
                "source": .object([
                    "kind": .string("base64"),
                    "mimeType": .string("image/jpeg"),
                    "data": .string("Zm9vYmFy")
                ])
            ])]
        )
        let calls = await provider.receivedContent
        #expect(calls.count == 1)
        // First block is always the rendered text prompt; second is
        // the resolved image attachment.
        guard let firstCall = calls.first else {
            Issue.record("Expected one multimodal call recorded")
            return
        }
        guard case let .text(promptText) = firstCall.first else {
            Issue.record("First block should be .text")
            return
        }
        #expect(promptText == "What is in this image?")
        if firstCall.count > 1 {
            #expect(firstCall[1].modality == .image)
        } else {
            Issue.record("Expected at least 2 blocks (text + image)")
        }
    }

    @Test("Missing attachment binding throws multimodalAttachmentInvalid")
    func missingAttachmentBindingThrows() async throws {
        let provider = RecordingMultimodalProvider(payload: .null)
        let step = LLMStep(
            promptTemplate: "x",
            outputBinding: "y",
            attachmentBindings: ["never_set"]
        )
        let workflow = Workflow(id: UUID(), name: "vision-fail", nodes: [.llm(step)])
        let runner = try await makeRunner(provider: provider)
        await #expect(throws: WorkflowEngineError.self) {
            _ = try await runner.run(workflow)
        }
    }

    // MARK: - SubAgent path

    @Test("SubAgentStep without executor throws subAgentExecutorUnavailable")
    func subAgentWithoutExecutorThrows() async throws {
        let provider = ConstantStructuredProvider(payload: .null)
        let step = SubAgentStep(
            agentDefinitionID: UUID(),
            outputBinding: "result"
        )
        let workflow = Workflow(id: UUID(), name: "subagent-fail", nodes: [.subAgent(step)])
        // Build a compiler WITHOUT subAgentExecutor — this should
        // pass compile (the step is valid syntactically) but the
        // run hits the missing-executor branch.
        let runner = try await makeRunner(provider: provider, subAgentExecutor: nil)
        await #expect(throws: WorkflowEngineError.self) {
            _ = try await runner.run(workflow)
        }
    }

    @Test("SubAgentStep binds the executor's SubAgentResult as {text, structured}")
    func subAgentBindsResult() async throws {
        let provider = ConstantStructuredProvider(payload: .null)
        let executor = StubSubAgentExecutor(result: SubAgentResult(
            text: "the answer is 42",
            structured: .object(["answer": .integer(42)])
        ))
        let agentID = UUID()
        let subAgent = SubAgentStep(
            agentDefinitionID: agentID,
            outputBinding: "agentResult"
        )
        let output = OutputStep(fields: [
            "text": "{{agentResult.text}}",
            "structuredAnswer": "{{agentResult.structured.answer}}"
        ])
        let workflow = Workflow(
            id: UUID(),
            name: "subagent-ok",
            nodes: [.subAgent(subAgent), .output(output)]
        )
        let runner = try await makeRunner(
            provider: provider,
            subAgentExecutor: executor
        )
        let result = try await runner.run(workflow)
        // OutputStep returns string-formatted bindings; the structured
        // answer shows up as "42" once interpolated.
        #expect(result["text"] == .string("the answer is 42"))
        #expect(result["structuredAnswer"] == .string("42"))
        let calls = await executor.recordedCalls
        #expect(calls.count == 1)
        #expect(calls.first?.agentID == agentID)
    }

    // MARK: - Helpers

    private func makeRunner(
        provider: any WorkflowLLMProvider,
        subAgentExecutor: (any SubAgentExecutor)? = nil
    ) async throws -> WorkflowRunner {
        let broker = CapabilityBroker(firstPartyCallerPrefix: "test.")
        let compiler = WorkflowCompiler(
            broker: broker,
            llmProvider: provider,
            subAgentExecutor: subAgentExecutor
        )
        return WorkflowRunner(compiler: compiler)
    }
}

// MARK: - Synthetic providers

/// First N attempts throw a decode-failure; subsequent attempts
/// return `successPayload`. Tracks attempt count for assertions.
private actor FlakyProvider: WorkflowLLMProvider {
    init(failAttempts: Int, successPayload: JSONValue) {
        self.failAttempts = failAttempts
        self.successPayload = successPayload
    }

    let failAttempts: Int
    let successPayload: JSONValue
    var attemptCount = 0

    nonisolated var capabilities: WorkflowProviderCapabilities {
        WorkflowProviderCapabilities(supportsStructuredOutput: true)
    }

    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        "unused — flaky tests use structured path"
    }

    func generateStructured(
        prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?, schemaID _: String
    ) async throws -> JSONValue {
        attemptCount += 1
        if attemptCount <= failAttempts {
            throw WorkflowEngineError.underlying(
                "structured-output text did not parse as JSON: synthetic"
            )
        }
        return successPayload
    }
}

private struct SleepyProvider: WorkflowLLMProvider {
    let sleepDuration: Duration
    var capabilities: WorkflowProviderCapabilities { WorkflowProviderCapabilities() }
    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        try await Task.sleep(for: sleepDuration)
        return "never"
    }
}

private struct ConstantStructuredProvider: WorkflowLLMProvider {
    let payload: JSONValue
    var capabilities: WorkflowProviderCapabilities {
        WorkflowProviderCapabilities(supportsStructuredOutput: true)
    }
    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        "ignored — structured path covers it"
    }
    func generateStructured(
        prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?, schemaID _: String
    ) async throws -> JSONValue {
        payload
    }
}

private struct StreamingProvider: WorkflowLLMProvider {
    let snapshots: [JSONValue]
    var capabilities: WorkflowProviderCapabilities {
        WorkflowProviderCapabilities(
            supportsStructuredOutput: true,
            supportsStreamingStructured: true
        )
    }
    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        ""
    }
    func generateStructured(
        prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?, schemaID _: String
    ) async throws -> JSONValue {
        snapshots.last ?? .null
    }
    func streamStructured(
        prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?, schemaID _: String
    ) -> AsyncThrowingStream<JSONValue, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                for snap in snapshots {
                    continuation.yield(snap)
                }
                continuation.finish()
            }
        }
    }
}

private actor RecordingMultimodalProvider: WorkflowLLMProvider {
    init(payload: JSONValue) {
        self.payload = payload
    }
    let payload: JSONValue
    var receivedContent: [[ContentBlock]] = []
    nonisolated var capabilities: WorkflowProviderCapabilities {
        WorkflowProviderCapabilities(
            supportsStructuredOutput: true,
            supportedModalities: [.text, .image]
        )
    }
    nonisolated func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        "unused"
    }
    func generateMultimodal(
        content: [ContentBlock],
        hint _: ModelFamilyHint,
        maxTokens _: Int?,
        schemaID _: String?
    ) async throws -> JSONValue {
        receivedContent.append(content)
        return payload
    }
}

private actor StubSubAgentExecutor: SubAgentExecutor {
    struct Call {
        let agentID: UUID
        let inputs: [String: JSONValue]
        let attended: Bool
    }
    init(result: SubAgentResult) {
        self.result = result
    }
    let result: SubAgentResult
    var recordedCalls: [Call] = []
    func run(
        agentDefinitionID: UUID,
        inputs: [String: JSONValue],
        maxSteps _: Int?,
        attended: Bool
    ) async throws -> SubAgentResult {
        recordedCalls.append(Call(
            agentID: agentDefinitionID,
            inputs: inputs,
            attended: attended
        ))
        return result
    }
}
