#if canImport(JavaScriptCore)
    import Aria
    import Foundation
    import Testing
    @testable import WorkflowKit

    // MARK: - WorkflowPluginToolRunnerTests

    /// Coverage for `PluginToolStep` compiler emission via a
    /// stub `PluginToolBroker`. The real `JSPluginToolBroker`
    /// (which wraps `AriaToolsJS.JSToolProvider`) is integration-
    /// tested implicitly through the app build; the unit tests
    /// here verify the lowering / argument templating /
    /// missing-broker behavior in isolation.
    struct WorkflowPluginToolRunnerTests {
        // MARK: Internal

        @Test
        func pluginToolStepInvokesBrokerAndWritesResult() async throws {
            let broker = RecordingPluginBroker(
                response: .object(["greeting": .string("hello, ada")])
            )
            let step = PluginToolStep(
                pluginID: "com.example.greet",
                argsTemplate: ["name": "{{input.name}}"],
                outputBinding: "greet"
            )
            let workflow = Workflow(
                name: "GreetingViaPlugin",
                outputSchema: OutputSchema(fields: [OutputField(id: "out", label: "Greeting")]),
                nodes: [
                    .pluginTool(step),
                    .output(OutputStep(fields: ["out": "{{greet.greeting}}"])),
                ]
            )

            let result = try await Self.makeRunner(broker: broker).run(
                workflow,
                input: ["name": .string("ada")],
                callerPluginID: "avyra.builtin.test"
            )

            #expect(result["out"] == .string("hello, ada"))
            #expect(broker.invocations.count == 1)
            #expect(broker.invocations.first?.pluginID == "com.example.greet")
            #expect(broker.invocations.first?.input == .object([
                "name": .string("ada"),
            ]))
        }

        @Test
        func pluginToolStepThrowsWhenBrokerUnavailable() async throws {
            let step = PluginToolStep(
                pluginID: "com.example.any",
                outputBinding: "out"
            )
            let workflow = Workflow(
                name: "NoBroker",
                nodes: [
                    .pluginTool(step),
                    .output(OutputStep(fields: [:])),
                ]
            )

            // Compiler constructed *without* a pluginToolBroker.
            let compiler = WorkflowCompiler(
                broker: CapabilityBroker(),
                llmProvider: StaticPluginProvider(),
                jsEvaluator: ThrowingJSEvaluator()
            )
            let runner = WorkflowRunner(compiler: compiler)

            await #expect(throws: WorkflowEngineError.pluginToolBrokerUnavailable) {
                _ = try await runner.run(
                    workflow,
                    input: [:],
                    callerPluginID: "avyra.builtin.test"
                )
            }
        }

        @Test
        func pluginToolStepUnknownPluginIDPropagates() async throws {
            let broker = ThrowingPluginBroker(
                error: WorkflowEngineError.unknownPluginTool("com.example.missing")
            )
            let step = PluginToolStep(
                pluginID: "com.example.missing",
                outputBinding: "out"
            )
            let workflow = Workflow(
                name: "MissingPlugin",
                nodes: [
                    .pluginTool(step),
                    .output(OutputStep(fields: [:])),
                ]
            )

            await #expect(
                throws: WorkflowEngineError.unknownPluginTool("com.example.missing")
            ) {
                _ = try await Self.makeRunner(broker: broker).run(
                    workflow,
                    input: [:],
                    callerPluginID: "avyra.builtin.test"
                )
            }
        }

        // MARK: Private

        // MARK: Helpers

        private static func makeRunner(broker: any PluginToolBroker) -> WorkflowRunner {
            let compiler = WorkflowCompiler(
                broker: CapabilityBroker(),
                llmProvider: StaticPluginProvider(),
                jsEvaluator: ThrowingJSEvaluator(),
                pluginToolBroker: broker
            )
            return WorkflowRunner(compiler: compiler)
        }
    }

    // MARK: - RecordingPluginBroker

    /// Captures every invocation so tests can assert on the
    /// plugin id + resolved input the compiler passed through.
    /// Returns the same canned response for every call.
    ///
    /// `invocations` access is unsynchronised — the workflow
    /// runner invokes a single plugin step per workflow run in
    /// these tests, so there's no contention. `@unchecked
    /// Sendable` reflects that we're vouching for the test's
    /// single-threaded shape rather than locking.
    private final class RecordingPluginBroker: PluginToolBroker, @unchecked Sendable {
        // MARK: Lifecycle

        init(response: JSONValue) {
            self.response = response
        }

        // MARK: Internal

        struct Invocation {
            let pluginID: String
            let input: JSONValue
        }

        let response: JSONValue
        private(set) var invocations: [Invocation] = []

        func invoke(pluginID: String, input: JSONValue) async throws -> JSONValue {
            self.invocations.append(Invocation(pluginID: pluginID, input: input))
            return self.response
        }
    }

    // MARK: - ThrowingPluginBroker

    /// Stand-in for the broker raising whatever the test wants
    /// to assert propagates out unchanged.
    private struct ThrowingPluginBroker: PluginToolBroker {
        let error: any Error

        func invoke(pluginID _: String, input _: JSONValue) async throws -> JSONValue {
            throw self.error
        }
    }

    // MARK: - StaticPluginProvider

    private struct StaticPluginProvider: WorkflowLLMProvider {
        func generate(
            prompt _: String,
            hint _: ModelFamilyHint,
            maxTokens _: Int?
        ) async throws -> String {
            "unused"
        }
    }
#endif
