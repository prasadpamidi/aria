import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - WorkflowRunnerTests

/// End-to-end coverage for the compile-and-run path. Uses a
/// mock LLM provider + mock capability so the test isn't
/// dependent on FoundationModels / EventKit / etc. — the
/// integration this slice cares about is the engine's wiring
/// itself.
struct WorkflowRunnerTests {
    @Test
    func linearWorkflowExecutesInOrder() async throws {
        // Workflow shape:
        //   1. capability: calendar.eventsToday -> events
        //   2. llm: "summarize {{events}}" -> summary
        //   3. output: spoken_text = "{{summary}}"
        let fakeProvider = FakeLLMProvider(reply: "Daily brief: 3 events.")
        let broker = CapabilityBroker()
        await broker.register(EchoCalendar())

        let compiler = WorkflowCompiler(broker: broker, llmProvider: fakeProvider)
        let runner = WorkflowRunner(compiler: compiler)

        let workflow = Workflow(
            name: "Daily Brief",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "spoken_text", label: "Spoken text"),
            ]),
            nodes: [
                .capability(CapabilityStep(
                    capability: .calendar,
                    method: "eventsToday",
                    outputBinding: "events"
                )),
                .llm(LLMStep(
                    promptTemplate: "Summarise: {{events}}",
                    outputBinding: "summary"
                )),
                .output(OutputStep(fields: [
                    "spoken_text": "{{summary}}",
                ])),
            ],
            triggers: [.manual]
        )

        let result = try await runner.run(
            workflow,
            callerPluginID: "avyra.builtin.test"
        )

        #expect(result["spoken_text"] == .string("Daily brief: 3 events."))
        // Confirm the LLM received the interpolated prompt that
        // saw the capability's output.
        #expect(fakeProvider.lastPrompt?.contains("Summarise:") == true)
        #expect(fakeProvider.lastPrompt?.contains("Standup") == true)
    }

    @Test
    func inputParametersAreReachableViaTemplate() async throws {
        let fakeProvider = FakeLLMProvider(reply: "ack")
        let broker = CapabilityBroker()
        let compiler = WorkflowCompiler(broker: broker, llmProvider: fakeProvider)
        let runner = WorkflowRunner(compiler: compiler)

        let workflow = Workflow(
            name: "Echo",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "greeted", label: "Greeted"),
            ]),
            nodes: [
                .llm(LLMStep(
                    promptTemplate: "Greet {{input.name}}",
                    outputBinding: "summary"
                )),
                .output(OutputStep(fields: [
                    "greeted": "{{summary}} for {{input.name}}",
                ])),
            ]
        )

        let result = try await runner.run(
            workflow,
            input: ["name": .string("Prasad")],
            callerPluginID: "avyra.builtin.test"
        )

        #expect(result["greeted"] == .string("ack for Prasad"))
        #expect(fakeProvider.lastPrompt == "Greet Prasad")
    }

    @Test
    func unregisteredCapabilitySurfaces() async throws {
        let fakeProvider = FakeLLMProvider(reply: "x")
        let broker = CapabilityBroker()
        // No capability registered.

        let compiler = WorkflowCompiler(broker: broker, llmProvider: fakeProvider)
        let runner = WorkflowRunner(compiler: compiler)

        let workflow = Workflow(
            name: "Missing Cap",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "spoken_text", label: "Spoken text"),
            ]),
            nodes: [
                .capability(CapabilityStep(
                    capability: .calendar,
                    method: "eventsToday",
                    outputBinding: "events"
                )),
                .output(OutputStep(fields: ["spoken_text": "{{events}}"])),
            ]
        )

        await #expect(throws: (any Error).self) {
            _ = try await runner.run(workflow, callerPluginID: "avyra.builtin.test")
        }
    }

    @Test
    func capabilityArgsAreInterpolated() async throws {
        let fakeProvider = FakeLLMProvider(reply: "n/a")
        let broker = CapabilityBroker()
        let recorder = RecordingCapability(id: .http, methods: ["request"])
        await broker.register(recorder)

        let compiler = WorkflowCompiler(broker: broker, llmProvider: fakeProvider)
        let runner = WorkflowRunner(compiler: compiler)

        let workflow = Workflow(
            name: "Templated Args",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "body", label: "Body"),
            ]),
            nodes: [
                .capability(CapabilityStep(
                    capability: .http,
                    method: "request",
                    argsTemplate: [
                        "url": "https://example.com/{{input.path}}",
                    ],
                    outputBinding: "body"
                )),
                .output(OutputStep(fields: ["body": "{{body}}"])),
            ]
        )

        _ = try await runner.run(
            workflow,
            input: ["path": .string("v1/today")],
            callerPluginID: "avyra.builtin.test"
        )

        // RecordingCapability captures the args it received; we
        // assert that the templated arg was resolved before the
        // call landed.
        let captured = await recorder.lastArguments
        #expect(captured["url"] == .string("https://example.com/v1/today"))
    }

    // MARK: - Empty / invalid

    @Test
    func emptyWorkflowFailsAtCompile() async {
        let fakeProvider = FakeLLMProvider(reply: "")
        let broker = CapabilityBroker()
        let compiler = WorkflowCompiler(broker: broker, llmProvider: fakeProvider)

        let workflow = Workflow(name: "Empty")
        #expect(throws: (any Error).self) {
            _ = try compiler.compile(workflow, callerPluginID: "avyra.builtin.test")
        }
    }
}

// MARK: - FakeLLMProvider

/// Deterministic provider that records the last prompt it saw.
private final class FakeLLMProvider: WorkflowLLMProvider, @unchecked Sendable {
    // MARK: Lifecycle

    init(reply: String) {
        self.reply = reply
    }

    // MARK: Internal

    private(set) var lastPrompt: String?

    func generate(prompt: String, hint _: ModelFamilyHint, maxTokens _: Int?) async throws -> String {
        self.lastPrompt = prompt
        return self.reply
    }

    // MARK: Private

    private let reply: String
}

// MARK: - EchoCalendar

/// Stand-in for the real CalendarCapability — returns a single
/// event so capability-step output flows into the LLM step's
/// template.
private struct EchoCalendar: Capability {
    var id: CapabilityID {
        .calendar
    }

    var supportedMethods: Set<String> {
        ["eventsToday"]
    }

    func call(
        method _: String,
        arguments _: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        .array([
            .object([
                "title": .string("Standup"),
                "start": .string("09:00"),
            ]),
        ])
    }
}

// MARK: - RecordingCapability

/// Captures the args it was called with so tests can assert
/// template interpolation landed correctly.
private actor RecordingCapability: Capability {
    // MARK: Lifecycle

    init(id: CapabilityID, methods: Set<String>) {
        self.id = id
        self.supportedMethods = methods
    }

    // MARK: Internal

    let id: CapabilityID
    let supportedMethods: Set<String>

    private(set) var lastArguments: [String: JSONValue] = [:]

    func call(
        method _: String,
        arguments: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        self.lastArguments = arguments
        return .string("ok")
    }
}
