import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - ServerLLMProviderRoutingTests

/// Coverage for the new `serverLLMResolver` injection seam on
/// `WorkflowCompiler`. Verifies the resolver fires for steps
/// that declare a `serverProviderID`, falls back to the default
/// provider when the resolver isn't wired or returns nil, and
/// also activates inside loop bodies.
struct ServerLLMProviderRoutingTests {
    // MARK: Internal

    @Test
    func resolverIsCalledWhenStepDeclaresServerProviderID() async throws {
        let defaultProvider = TaggedProvider(reply: "default")
        let serverProvider = TaggedProvider(reply: "server")
        let pinned = UUID()
        let resolver: ServerLLMProviderResolver = { id in
            id == pinned ? serverProvider : nil
        }
        let runner = try await Self.makeRunner(
            defaultProvider: defaultProvider,
            resolver: resolver
        )
        let workflow = Self.singleLLMWorkflow(serverProviderID: pinned)

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        #expect(result["spoken_text"] == .string("server"))
        #expect(serverProvider.lastPrompt?.contains("Hello") == true)
        #expect(defaultProvider.lastPrompt == nil)
    }

    @Test
    func fallsBackToDefaultWhenStepHasNoServerProviderID() async throws {
        let defaultProvider = TaggedProvider(reply: "default")
        let serverProvider = TaggedProvider(reply: "server")
        let resolver: ServerLLMProviderResolver = { _ in serverProvider }
        let runner = try await Self.makeRunner(
            defaultProvider: defaultProvider,
            resolver: resolver
        )
        let workflow = Self.singleLLMWorkflow(serverProviderID: nil)

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        #expect(result["spoken_text"] == .string("default"))
        #expect(serverProvider.lastPrompt == nil)
    }

    @Test
    func fallsBackToDefaultWhenResolverReturnsNil() async throws {
        let defaultProvider = TaggedProvider(reply: "default")
        let resolver: ServerLLMProviderResolver = { _ in nil }
        let runner = try await Self.makeRunner(
            defaultProvider: defaultProvider,
            resolver: resolver
        )
        let workflow = Self.singleLLMWorkflow(serverProviderID: UUID())

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        #expect(result["spoken_text"] == .string("default"))
        #expect(defaultProvider.lastPrompt?.contains("Hello") == true)
    }

    @Test
    func resolverIsHonouredInsideLoopBody() async throws {
        // Loops re-implement step execution inline (see
        // `WorkflowCompiler.executeBodyNode`). This test covers
        // the symmetry: an LLM step nested inside a loop body
        // must consult the same resolver as a top-level LLM step.
        let defaultProvider = TaggedProvider(reply: "default")
        let serverProvider = TaggedProvider(reply: "server")
        let pinned = UUID()
        let resolver: ServerLLMProviderResolver = { id in
            id == pinned ? serverProvider : nil
        }
        let runner = try await Self.makeRunner(
            defaultProvider: defaultProvider,
            resolver: resolver
        )

        let bodyLLMID = UUID()
        let workflow = Workflow(
            name: "loop with server llm",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "spoken_text", label: "Spoken text"),
            ]),
            nodes: [
                .loop(LoopStep(
                    condition: "(b.i ?? 0) < 1",
                    body: [bodyLLMID],
                    maxIterations: 3,
                    iterationBinding: "i"
                )),
                .llm(LLMStep(
                    id: bodyLLMID,
                    promptTemplate: "Hi",
                    outputBinding: "reply",
                    serverProviderID: pinned
                )),
                .output(OutputStep(fields: [
                    "spoken_text": "{{reply}}",
                ])),
            ],
            triggers: [.manual]
        )

        let result = try await runner.run(
            workflow,
            callerPluginID: "sdk.builtin.test"
        )

        #expect(result["spoken_text"] == .string("server"))
        #expect(defaultProvider.lastPrompt == nil)
    }

    // MARK: Private

    // MARK: - Helpers

    private static func makeRunner(
        defaultProvider: any WorkflowLLMProvider,
        resolver: ServerLLMProviderResolver?
    ) async throws -> WorkflowRunner {
        let broker = CapabilityBroker()
        // The routing tests don't actually execute any JS — every
        // workflow they build is LLM steps + outputs. Substitute
        // `ThrowingJSEvaluator` on Linux where `JavaScriptCore`
        // isn't available; Apple platforms still use the real
        // evaluator so any test that DOES want JS keeps working.
        #if canImport(JavaScriptCore)
            let evaluator: any WorkflowJSEvaluator = try JavaScriptCoreJSEvaluator()
        #else
            let evaluator: any WorkflowJSEvaluator = ThrowingJSEvaluator()
        #endif
        let compiler = WorkflowCompiler(
            broker: broker,
            llmProvider: defaultProvider,
            jsEvaluator: evaluator,
            pluginToolBroker: nil,
            serverLLMResolver: resolver
        )
        return WorkflowRunner(compiler: compiler)
    }

    private static func singleLLMWorkflow(serverProviderID: UUID?) -> Workflow {
        Workflow(
            name: "single llm",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "spoken_text", label: "Spoken text"),
            ]),
            nodes: [
                .llm(LLMStep(
                    promptTemplate: "Hello",
                    outputBinding: "reply",
                    serverProviderID: serverProviderID
                )),
                .output(OutputStep(fields: [
                    "spoken_text": "{{reply}}",
                ])),
            ],
            triggers: [.manual]
        )
    }
}

// MARK: - TaggedProvider

/// Provider that records the last prompt it saw and returns a
/// fixed reply. Two instances let tests assert *which* provider
/// the engine routed through — the source of truth for whether
/// the resolver fired.
private final class TaggedProvider: WorkflowLLMProvider, @unchecked Sendable {
    // MARK: Lifecycle

    init(reply: String) {
        self.reply = reply
    }

    // MARK: Internal

    private(set) var lastPrompt: String?
    private(set) var prewarmCount = 0
    private(set) var prewarmFiredBeforeGenerate = false

    func prewarm() async throws {
        self.prewarmCount += 1
        // Track that prewarm landed BEFORE we saw a generate call —
        // the engine should warm up first, then run.
        if self.lastPrompt == nil {
            self.prewarmFiredBeforeGenerate = true
        }
    }

    func generate(prompt: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        self.lastPrompt = prompt
        return self.reply
    }

    // MARK: Private

    private let reply: String
}

// MARK: - LLMProviderPrewarmTests

struct LLMProviderPrewarmTests {
    @Test
    func prewarmFiresBeforeGenerateOnEveryLLMStep() async throws {
        let provider = TaggedProvider(reply: "ok")
        let broker = CapabilityBroker()
        let compiler = WorkflowCompiler(
            broker: broker,
            llmProvider: provider
        )
        let runner = WorkflowRunner(compiler: compiler)
        let workflow = Workflow(
            name: "prewarm",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "spoken_text", label: "Spoken text"),
            ]),
            nodes: [
                .llm(LLMStep(promptTemplate: "Hi", outputBinding: "reply")),
                .output(OutputStep(fields: ["spoken_text": "{{reply}}"])),
            ],
            triggers: [.manual]
        )

        _ = try await runner.run(workflow, callerPluginID: "sdk.builtin.test")

        #expect(provider.prewarmCount == 1)
        #expect(provider.prewarmFiredBeforeGenerate)
        #expect(provider.lastPrompt == "Hi")
    }

    @Test
    func prewarmErrorsAreSwallowedAndGenerateStillRuns() async throws {
        let provider = ThrowingPrewarmProvider(reply: "still works")
        let broker = CapabilityBroker()
        let compiler = WorkflowCompiler(
            broker: broker,
            llmProvider: provider
        )
        let runner = WorkflowRunner(compiler: compiler)
        let workflow = Workflow(
            name: "prewarm-error",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "spoken_text", label: "Spoken text"),
            ]),
            nodes: [
                .llm(LLMStep(promptTemplate: "Hi", outputBinding: "reply")),
                .output(OutputStep(fields: ["spoken_text": "{{reply}}"])),
            ],
            triggers: [.manual]
        )

        let result = try await runner.run(workflow, callerPluginID: "sdk.builtin.test")

        #expect(result["spoken_text"] == .string("still works"))
        #expect(provider.prewarmCalled)
    }
}

// MARK: - ThrowingPrewarmProvider

/// Provider whose `prewarm()` throws — used to confirm the
/// engine treats prewarm errors as advisory and lets the step
/// continue into `generate`.
private final class ThrowingPrewarmProvider: WorkflowLLMProvider, @unchecked Sendable {
    // MARK: Lifecycle

    init(reply: String) {
        self.reply = reply
    }

    // MARK: Internal

    private(set) var prewarmCalled = false

    func prewarm() async throws {
        self.prewarmCalled = true
        throw NSError(domain: "Test", code: 1)
    }

    func generate(prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        self.reply
    }

    // MARK: Private

    private let reply: String
}
