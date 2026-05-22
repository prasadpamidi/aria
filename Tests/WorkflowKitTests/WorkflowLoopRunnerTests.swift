#if canImport(JavaScriptCore)
    import Aria
    import Foundation
    import Testing
    @testable import WorkflowKit

    // MARK: - WorkflowLoopRunnerTests

    /// End-to-end coverage for `LoopStep` through the real
    /// `JavaScriptCoreJSEvaluator`. Verifies the four control-
    /// flow corners (run-until-false, never-enter, early-break,
    /// max-iterations) plus the iteration counter binding and
    /// the unsupported-body-variant guard.
    struct WorkflowLoopRunnerTests {
        // MARK: Internal

        @Test
        func loopRunsBodyUntilConditionGoesFalsy() async throws {
            let increment = TransformStep(
                jsExpression: "(b.counter || 0) + 1",
                outputBinding: "counter"
            )
            let loop = LoopStep(
                condition: "(b.counter || 0) < 5",
                body: [increment.id]
            )
            let workflow = Workflow(
                name: "CountToFive",
                outputSchema: OutputSchema(fields: [OutputField(id: "final", label: "Final")]),
                nodes: [
                    .loop(loop),
                    .transform(increment),
                    .output(OutputStep(fields: ["final": "{{counter}}"])),
                ]
            )

            let result = try await Self.makeRunner().run(
                workflow,
                input: [:],
                callerPluginID: "avyra.builtin.test"
            )

            #expect(result["final"] == .string("5"))
        }

        @Test
        func loopExitsImmediatelyWhenConditionStartsFalsy() async throws {
            let increment = TransformStep(
                jsExpression: "(b.counter || 0) + 1",
                outputBinding: "counter"
            )
            let loop = LoopStep(
                condition: "false",
                body: [increment.id]
            )
            let workflow = Workflow(
                name: "NeverEnters",
                outputSchema: OutputSchema(fields: [OutputField(id: "final", label: "Final")]),
                nodes: [
                    .loop(loop),
                    .transform(increment),
                    .output(OutputStep(fields: ["final": "{{counter}}"])),
                ]
            )

            let result = try await Self.makeRunner().run(
                workflow,
                input: [:],
                callerPluginID: "avyra.builtin.test"
            )

            // `b.counter` was never written, so the template
            // interpolator renders the empty string.
            #expect(result["final"] == .string(""))
        }

        @Test
        func loopBreaksEarlyWhenBreakOnFires() async throws {
            let increment = TransformStep(
                jsExpression: "(b.counter || 0) + 1",
                outputBinding: "counter"
            )
            // Condition would let the loop run to 100; breakOn
            // stops it at 3 so the final counter must be 3.
            let loop = LoopStep(
                condition: "(b.counter || 0) < 100",
                body: [increment.id],
                breakOn: "b.counter >= 3"
            )
            let workflow = Workflow(
                name: "BreakAtThree",
                outputSchema: OutputSchema(fields: [OutputField(id: "final", label: "Final")]),
                nodes: [
                    .loop(loop),
                    .transform(increment),
                    .output(OutputStep(fields: ["final": "{{counter}}"])),
                ]
            )

            let result = try await Self.makeRunner().run(
                workflow,
                input: [:],
                callerPluginID: "avyra.builtin.test"
            )

            #expect(result["final"] == .string("3"))
        }

        @Test
        func loopThrowsWhenMaxIterationsExceeded() async throws {
            let noop = TransformStep(
                jsExpression: "1",
                outputBinding: "unused"
            )
            // Always-true condition + no break + tight cap.
            let loop = LoopStep(
                condition: "true",
                body: [noop.id],
                maxIterations: 5
            )
            let workflow = Workflow(
                name: "Runaway",
                nodes: [
                    .loop(loop),
                    .transform(noop),
                    .output(OutputStep(fields: [:])),
                ]
            )

            await #expect(throws: WorkflowEngineError.loopMaxIterationsExceeded) {
                _ = try await Self.makeRunner().run(
                    workflow,
                    input: [:],
                    callerPluginID: "avyra.builtin.test"
                )
            }
        }

        @Test
        func loopExposesIterationCounterAsBinding() async throws {
            let echo = TransformStep(
                jsExpression: "b.i",
                outputBinding: "lastSeenIndex"
            )
            let loop = LoopStep(
                condition: "(b.i || 0) < 3",
                body: [echo.id],
                iterationBinding: "i"
            )
            let workflow = Workflow(
                name: "Echo",
                outputSchema: OutputSchema(fields: [OutputField(id: "final", label: "Final")]),
                nodes: [
                    .loop(loop),
                    .transform(echo),
                    .output(OutputStep(fields: ["final": "{{lastSeenIndex}}"])),
                ]
            )

            let result = try await Self.makeRunner().run(
                workflow,
                input: [:],
                callerPluginID: "avyra.builtin.test"
            )

            // Final iteration's index = 2 (0,1,2 then condition
            // re-evaluates with i=3 which fails).
            #expect(result["final"] == .string("2"))
        }

        @Test
        func loopBodyContainingUnsupportedNodeThrows() async throws {
            let nestedOutput = OutputStep(fields: ["x": "{{i}}"])
            let loop = LoopStep(
                condition: "true",
                body: [nestedOutput.id],
                maxIterations: 5
            )
            let workflow = Workflow(
                name: "BadBody",
                nodes: [
                    .loop(loop),
                    .output(nestedOutput),
                ]
            )

            await #expect(throws: WorkflowEngineError.loopBodyContainsUnsupportedNode("output")) {
                _ = try await Self.makeRunner().run(
                    workflow,
                    input: [:],
                    callerPluginID: "avyra.builtin.test"
                )
            }
        }

        // MARK: Private

        // MARK: Helpers

        private static func makeRunner() throws -> WorkflowRunner {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let compiler = WorkflowCompiler(
                broker: CapabilityBroker(),
                llmProvider: StaticLoopProvider(),
                jsEvaluator: evaluator
            )
            return WorkflowRunner(compiler: compiler)
        }
    }

    // MARK: - StaticLoopProvider

    private struct StaticLoopProvider: WorkflowLLMProvider {
        func generate(
            prompt _: String,
            hint _: ModelFamilyHint,
            maxTokens _: Int?
        ) async throws -> String {
            "unused"
        }
    }
#endif
