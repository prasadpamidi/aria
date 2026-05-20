#if canImport(JavaScriptCore)
    import Aria
    import Foundation
    import Testing
    @testable import WorkflowKit

    // MARK: - WorkflowBranchRunnerTests

    /// End-to-end coverage for `TransformStep` and `BranchStep`
    /// through the real `JavaScriptCoreJSEvaluator`. Slice 5's
    /// tests covered the linear capability/LLM/output flow with
    /// a stub evaluator; this suite proves the branching + JS
    /// transformation paths are wired correctly now that the
    /// real evaluator is in.
    struct WorkflowBranchRunnerTests {
        @Test
        func transformStepWritesEvaluatedResultToBinding() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let broker = CapabilityBroker()
            let provider = StaticProvider(reply: "ignored")
            let compiler = WorkflowCompiler(
                broker: broker,
                llmProvider: provider,
                jsEvaluator: evaluator
            )
            let runner = WorkflowRunner(compiler: compiler)

            let workflow = Workflow(
                name: "Triple",
                outputSchema: OutputSchema(fields: [
                    OutputField(id: "result", label: "Result"),
                ]),
                nodes: [
                    .transform(TransformStep(
                        jsExpression: "b.input.value * 3",
                        outputBinding: "tripled"
                    )),
                    .output(OutputStep(fields: ["result": "{{tripled}}"])),
                ],
                triggers: [.manual]
            )

            let result = try await runner.run(
                workflow,
                input: ["value": .integer(7)],
                callerPluginID: "avyra.builtin.test"
            )

            #expect(result["result"] == .string("21"))
        }

        @Test
        func branchStepRoutesByPredicate() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let broker = CapabilityBroker()
            let provider = StaticProvider(reply: "ignored")
            let compiler = WorkflowCompiler(
                broker: broker,
                llmProvider: provider,
                jsEvaluator: evaluator
            )
            let runner = WorkflowRunner(compiler: compiler)

            // Three-node shape: branch -> transform-yes /
            // transform-no -> output. The branch's true list
            // points at transform-yes; the false list at
            // transform-no.
            let yes = TransformStep(jsExpression: "'YES'", outputBinding: "label")
            let no = TransformStep(jsExpression: "'NO'", outputBinding: "label")
            let outputStep = OutputStep(fields: ["chosen": "{{label}}"])
            let branchStep = BranchStep(
                condition: "b.input.flag",
                trueBranch: [yes.id],
                falseBranch: [no.id]
            )

            let workflow = Workflow(
                name: "Pick",
                outputSchema: OutputSchema(fields: [OutputField(id: "chosen", label: "Chosen")]),
                nodes: [
                    .branch(branchStep),
                    .transform(yes),
                    .transform(no),
                    .output(outputStep),
                ],
                triggers: [.manual]
            )

            let resultTrue = try await runner.run(
                workflow,
                input: ["flag": .bool(true)],
                callerPluginID: "avyra.builtin.test"
            )
            #expect(resultTrue["chosen"] == .string("YES"))

            let resultFalse = try await runner.run(
                workflow,
                input: ["flag": .bool(false)],
                callerPluginID: "avyra.builtin.test"
            )
            #expect(resultFalse["chosen"] == .string("NO"))
        }
    }

    // MARK: - StaticProvider

    private struct StaticProvider: WorkflowLLMProvider {
        let reply: String

        func generate(
            prompt _: String,
            hint _: ModelFamilyHint,
            maxTokens _: Int?
        ) async throws -> String {
            self.reply
        }
    }
#endif
