#if canImport(FoundationModels)

    import Aria
    import AriaApple
    import AriaTesting
    import FoundationModels
    import XCTest

    // MARK: - TaskEvalTests

    /// Does the harness earn its complexity?
    ///
    /// Everything measurable here until now was about *ranking* —
    /// whether the right tool was offered. That is a proxy, and the
    /// field traces are full of turns where the right tool was ranked
    /// first, called correctly, and the answer was still wrong.
    ///
    /// This measures the only thing a user experiences: did the turn
    /// work. And it measures it against a **baseline** — the same cases
    /// through a bare provider with no assembler, no selection, no
    /// budget. Without that arm a success rate says nothing about
    /// whether any of this was worth building.
    ///
    ///     TEST_RUNNER_ARIA_RUN_EVALS=1 xcodebuild test \
    ///       -scheme Aria-Package -destination 'platform=macOS,arch=arm64' \
    ///       -only-testing:AriaAppleTests/TaskEvalTests \
    ///       -skipPackagePluginValidation -skipMacroValidation
    @available(iOS 26.0, macOS 26.0, *)
    final class TaskEvalTests: XCTestCase {
        override func setUpWithError() throws {
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw XCTSkip("Requires iOS 26 / macOS 26 runtime")
            }
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["ARIA_RUN_EVALS"] == "1",
                "Runs a real model; set ARIA_RUN_EVALS=1"
            )
            try XCTSkipUnless(
                SystemLanguageModel.default.isAvailable,
                "Requires an available on-device model"
            )
        }

        /// The same comparison on a surface that does not fit.
        ///
        /// At twelve tools both arms fit the window, so selection has
        /// nothing to relieve and the two arms measure the same
        /// thing — which is what the first version of this test found,
        /// and it found it because of how it was built, not because of
        /// the harness. A connected MCP server brings tools by the
        /// dozen; this runs the identical cases against fifty.
        func testHarnessAgainstBareProviderOnALargeSurface() async throws {
            let cases = TaskFixtures.cases(surfaceSize: 50)
            let eval = TaskEval(cases: cases, trials: 3)

            let bare = await eval.run(label: "bare provider · 50 tools") { testCase in
                Agent(config: AgentConfig(
                    provider: Self.provider(for: testCase),
                    tools: testCase.tools,
                    systemPrompt: Self.systemPrompt
                ))
            }
            let configured = await eval.run(label: "configured · 50 tools") { testCase in
                Agent(config: AgentConfig(
                    provider: Self.provider(for: testCase),
                    tools: testCase.tools,
                    systemPrompt: Self.systemPrompt,
                    contextAssembler: DefaultContextAssembler(unrankedFillLimit: 0),
                    contextBudget: ContextBudget(
                        total: 4096,
                        reservedForOutput: 768,
                        maxTools: 6
                    )
                ))
            }

            print("\n" + bare.summary())
            print("\n" + configured.summary() + "\n")
        }

        /// Does selection help *below* the overflow threshold, when the
        /// tools are confusable?
        ///
        /// The twelve-tool comparison found no difference, and the
        /// distractors are the likely reason: `calculator` and
        /// `base64_codec` are trivially distinguishable from "how's my
        /// fasting going?", so nothing was being asked of picking. The
        /// field traces show the opposite shape — `start_fast` beside
        /// `get_fasting_status`, `log_weight` beside `log_water` — a
        /// question answered by a write.
        ///
        /// Both surfaces are twenty tools and both fit the window, so
        /// count and overflow are held constant and confusability is
        /// the only variable.
        func testConfusableSurfaceBelowTheOverflowThreshold() async throws {
            for confusable in [false, true] {
                let label = confusable ? "confusable" : "easy"
                let cases = TaskFixtures.cases(surfaceSize: 20, confusable: confusable)
                let eval = TaskEval(cases: cases, trials: 3)

                let bare = await eval.run(label: "bare · 20 \(label)") { testCase in
                    Agent(config: AgentConfig(
                        provider: Self.provider(for: testCase),
                        tools: testCase.tools,
                        systemPrompt: Self.systemPrompt
                    ))
                }
                let configured = await eval.run(label: "configured · 20 \(label)") { testCase in
                    Agent(config: AgentConfig(
                        provider: Self.provider(for: testCase),
                        tools: testCase.tools,
                        systemPrompt: Self.systemPrompt,
                        contextAssembler: DefaultContextAssembler(unrankedFillLimit: 0),
                        contextBudget: ContextBudget(
                            total: 4096,
                            reservedForOutput: 768,
                            maxTools: 6
                        )
                    ))
                }
                print("\n" + bare.summary())
                print(configured.summary() + "\n")
            }
        }

        func testHarnessAgainstBareProvider() async throws {
            // Three passes over the corpus, not one. Two runs of the
            // *identical* configuration scored 83% and 67% — with six
            // cases one case is 17 points, so a single pass reports
            // the sampler, not the harness.
            let eval = TaskEval(cases: TaskFixtures.cases(), trials: 3)

            let bare = await eval.run(label: "bare provider") { testCase in
                Agent(config: AgentConfig(
                    provider: Self.provider(for: testCase),
                    tools: testCase.tools,
                    systemPrompt: Self.systemPrompt
                ))
            }

            let configured = await eval.run(label: "configured") { testCase in
                Agent(config: AgentConfig(
                    provider: Self.provider(for: testCase),
                    tools: testCase.tools,
                    systemPrompt: Self.systemPrompt,
                    contextAssembler: DefaultContextAssembler(unrankedFillLimit: 0),
                    contextBudget: ContextBudget(
                        total: 4096,
                        reservedForOutput: 768,
                        maxTools: 6
                    )
                ))
            }

            print("\n" + bare.summary())
            print("\n" + configured.summary() + "\n")

            XCTAssertGreaterThan(
                configured.successRate,
                0,
                "A harness that completes no task is not a harness"
            )
        }

        // MARK: Private

        /// The instructions the per-model work landed on: nothing about
        /// how to call a tool, only about what may be claimed after.
        private static let systemPrompt = """
        You are a concise, helpful assistant.

        State only what the conversation or a tool result actually says. If a tool \
        fails or returns nothing, say so plainly rather than filling the gap. If a \
        tool needs a value you were not given, ask for it — never invent one, and \
        never leave a placeholder in a reply.
        """

        private static func provider(for testCase: TaskCase) -> any LLMProvider {
            FoundationModelsProvider(
                defaultInstructions: Self.systemPrompt,
                typedTools: testCase.tools.map { tool in
                    { yield in PassthroughTool(tool: tool, yieldEvent: yield) }
                }
            )
        }
    }

    // MARK: - PassthroughTool

    /// Bridges an `AnyTool` into the typed surface FoundationModels
    /// resolves against, so both arms run the identical tool set.
    ///
    /// **It must yield.** FoundationModels resolves tools inside its own
    /// session, so the only way a call becomes visible to the agent
    /// layer is the tool reporting it through the provider's event
    /// hook. A first version ignored that closure, and the eval scored
    /// every arm at 17% while the answers plainly carried the tools'
    /// own payloads — a broken instrument reporting a broken harness.
    @available(iOS 26.0, macOS 26.0, *)
    private struct PassthroughTool: FoundationModels.Tool {
        @Generable
        struct Arguments: Codable {
            @Guide(description: "Arguments as a JSON object, or {} when none are needed.")
            var argumentsJSON: String
        }

        typealias Output = String

        let tool: AnyTool
        let yieldEvent: @Sendable (ProviderEvent) -> Void

        var name: String { self.tool.definition.name }
        var description: String { self.tool.definition.description }

        func call(arguments _: Arguments) async throws -> String {
            let started = ContinuousClock.now
            let result = try await tool.invoke(.object([:]), ToolContext())
            self.yieldEvent(.toolCallExecuted(
                call: ToolCall(id: UUID().uuidString, name: self.name, arguments: .object([:])),
                result: ToolExecutionResult(
                    output: result,
                    isError: false,
                    duration: ContinuousClock.now - started
                )
            ))
            guard let data = try? result.canonicalData(),
                  let text = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return text
        }
    }

#endif
