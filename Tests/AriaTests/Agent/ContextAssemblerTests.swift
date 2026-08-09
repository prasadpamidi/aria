import Foundation
import XCTest
@testable import Aria

// MARK: - ContextAssemblerTests

/// Coverage for context assembly.
///
/// The defect that motivated this suite survived because nothing ever
/// measured the assembled prompt. `HistoryWindowMiddleware` reported
/// success while budgeting a few hundred tokens of history, unaware of
/// the several thousand tokens of tool schemas travelling to the model
/// beside it. Tests that only exercise the windowing algorithm cannot
/// catch that; tests that assert on the *whole assembled request* can.
final class ContextAssemblerTests: XCTestCase {
    // MARK: - Golden: the test that would have caught the original bug

    /// Asserts the total assembled cost, not the cost of one component.
    ///
    /// Deliberately measures system prompt + tools + history together,
    /// because the historical failure was precisely that these were
    /// each accounted for by a different component and never summed.
    func testAllocationAccountsForPromptToolsAndHistoryTogether() async {
        let assembler = DefaultContextAssembler()
        let state = AgentState(messages: [.user("How is it going?")])

        let assembled = await assembler.assemble(
            systemPrompt: "You are a concise assistant.",
            tools: [Self.tool(named: "log_meal", description: "Log a meal the user ate.")],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 512)
        )

        let allocation = assembled.allocation
        XCTAssertGreaterThan(allocation.systemPromptTokens, 0)
        XCTAssertGreaterThan(allocation.toolTokens, 0, "Tool cost must be visible to the budget")
        XCTAssertGreaterThan(allocation.historyTokens, 0)
        XCTAssertEqual(
            allocation.totalTokens,
            allocation.systemPromptTokens + allocation.toolTokens + allocation.historyTokens
        )
        // 4096 - 512 output reserve, less the 10% safety margin
        // that absorbs estimator error. See `ContextBudget.safetyMargin`.
        XCTAssertEqual(allocation.budgetAvailable, 3226)
    }

    /// Tool schemas must dominate the accounting when a surface is
    /// large — the real-world shape that broke a 1.2B model.
    func testLargeToolSurfaceDominatesAllocation() async {
        let assembler = DefaultContextAssembler()
        let tools = (0..<60).map {
            Self.tool(named: "tool_\($0)", description: "Does something specific numbered \($0).")
        }
        let assembled = await assembler.assemble(
            systemPrompt: "You are a concise assistant.",
            tools: tools,
            state: AgentState(messages: [.user("hi")]),
            budget: ContextBudget(total: 100_000)
        )

        let allocation = assembled.allocation
        XCTAssertGreaterThan(
            allocation.toolTokens,
            allocation.systemPromptTokens + allocation.historyTokens,
            "A 60-tool surface should visibly outweigh a short prompt and a two-word turn"
        )
    }

    // MARK: - Budget enforcement

    func testAssembledHistoryNeverExceedsBudget() async {
        let assembler = DefaultContextAssembler()
        let messages = (0..<200).map { Message.user("message number \($0) with some filler text") }
        let budget = ContextBudget(total: 400, reservedForOutput: 100)

        let assembled = await assembler.assemble(
            systemPrompt: "System.",
            tools: [],
            state: AgentState(messages: messages),
            budget: budget
        )

        XCTAssertLessThanOrEqual(assembled.allocation.totalTokens, budget.available)
        XCTAssertGreaterThan(assembled.allocation.messagesDropped, 0)
        XCTAssertTrue(assembled.allocation.didTruncate)
    }

    /// Even an over-budget final turn survives — the model needs
    /// something to answer.
    func testFinalMessageSurvivesAnImpossibleBudget() async {
        let assembler = DefaultContextAssembler()
        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: AgentState(messages: [.user(String(repeating: "x", count: 5000))]),
            budget: ContextBudget(total: 10, reservedForOutput: 0)
        )
        XCTAssertEqual(assembled.messages.count, 1)
    }

    func testSystemMessagesAreNeverDropped() async {
        let assembler = DefaultContextAssembler()
        var messages: [Message] = [.system("## Recalled memories\n- user Prasad")]
        messages.append(contentsOf: (0..<100).map { Message.user("filler \($0) with text") })

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: AgentState(messages: messages),
            budget: ContextBudget(total: 120, reservedForOutput: 20)
        )

        XCTAssertTrue(assembled.messages.contains { $0.role == .system })
    }

    // MARK: - Tool selection

    func testUnboundedBudgetSendsEveryToolAndSkipsRanking() async {
        let assembler = DefaultContextAssembler()
        let tools = (0..<20).map { Self.tool(named: "tool_\($0)", description: "Unrelated \($0).") }

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("something entirely unrelated")]),
            budget: ContextBudget(total: 100_000, maxTools: nil)
        )

        XCTAssertEqual(assembled.tools.count, 20)
    }

    func testToolCapIsRespected() async {
        let assembler = DefaultContextAssembler()
        let tools = (0..<20).map {
            Self.tool(named: "weather_\($0)", description: "Reports the weather for a city.")
        }
        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("what is the weather")]),
            budget: ContextBudget(total: 100_000, maxTools: 3)
        )
        XCTAssertLessThanOrEqual(assembled.tools.count, 3)
    }

    func testRelevantToolOutranksIrrelevantOne() async {
        let assembler = DefaultContextAssembler()
        let tools = [
            Self.tool(named: "convert_currency", description: "Convert between currencies."),
            Self.tool(named: "log_meal", description: "Record a meal the user ate today."),
            Self.tool(named: "rotate_image", description: "Rotate an image by degrees."),
        ]
        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("log the meal I just ate")]),
            budget: ContextBudget(total: 100_000, maxTools: 1)
        )
        XCTAssertEqual(assembled.tools.first?.name, "log_meal")
    }

    /// A tool invoked earlier in the run must remain available, or the
    /// tool result already in history refers to a call the model can no
    /// longer see.
    func testPreviouslyInvokedToolStaysAvailable() async {
        let assembler = DefaultContextAssembler()
        let tools = [
            Self.tool(named: "log_meal", description: "Record a meal."),
            Self.tool(named: "get_weather", description: "Weather for a city."),
        ]
        let state = AgentState(messages: [
            .user("log my breakfast"),
            .assistant("", toolCalls: [ToolCall(id: "1", name: "log_meal", arguments: .object([:]))]),
            .tool(callId: "1", text: "logged"),
            .user("now tell me something completely different about rotation"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: state,
            budget: ContextBudget(total: 100_000, maxTools: 1)
        )

        XCTAssertTrue(
            assembled.tools.contains { $0.name == "log_meal" },
            "Sticky tools must survive even when the current turn ranks them last"
        )
    }

    func testPinnedToolsAlwaysSurvive() async {
        let assembler = DefaultContextAssembler(pinnedToolNames: ["load_skill"])
        let tools = [
            Self.tool(named: "load_skill", description: "Fetch a skill body by name."),
            Self.tool(named: "get_weather", description: "Weather for a city."),
        ]
        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("what is the weather")]),
            budget: ContextBudget(total: 100_000, maxTools: 1)
        )
        XCTAssertTrue(assembled.tools.contains { $0.name == "load_skill" })
    }

    // MARK: - Guidance

    /// The structural fix for policy describing an absent tool: it can
    /// only appear when the tool it describes was actually sent.
    func testGuidanceAppearsOnlyForSelectedTools() async {
        let assembler = DefaultContextAssembler()
        let tools = [
            Self.tool(
                named: "log_meal",
                description: "Record a meal the user ate.",
                guidance: "Record meals the user reports eating."
            ),
            Self.tool(
                named: "remember_fact",
                description: "Store a durable fact about the user.",
                guidance: "Store durable first-person facts."
            ),
        ]
        let assembled = await assembler.assemble(
            systemPrompt: "You are a concise assistant.",
            tools: tools,
            state: AgentState(messages: [.user("log the meal I ate")]),
            budget: ContextBudget(total: 100_000, maxTools: 1)
        )

        let prompt = assembled.messages.first { $0.role == .system }?.textContent ?? ""
        XCTAssertTrue(prompt.contains("Record meals the user reports eating."))
        XCTAssertFalse(
            prompt.contains("Store durable first-person facts."),
            "Guidance for an unselected tool must not reach the prompt"
        )
    }

    func testNoGuidanceLeavesSystemPromptUntouched() async {
        let assembler = DefaultContextAssembler()
        let assembled = await assembler.assemble(
            systemPrompt: "You are a concise assistant.",
            tools: [Self.tool(named: "get_weather", description: "Weather.")],
            state: AgentState(messages: [.user("hi")]),
            budget: ContextBudget(total: 100_000)
        )
        let prompt = assembled.messages.first { $0.role == .system }?.textContent
        XCTAssertEqual(prompt, "You are a concise assistant.")
    }

    // MARK: - Helpers

    private static func tool(
        named name: String,
        description: String,
        guidance: String? = nil
    ) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: description,
                inputSchema: .object(properties: ["value": .string()], required: []),
                promptGuidance: guidance
            ),
            invoke: { _, _ in .null }
        )
    }
}

// MARK: - ContextAllocationReportingTests

/// The allocation is only useful if it escapes the assembler.
///
/// Computed-and-discarded accounting leaves a turn's cost as invisible
/// as it was before any budgeting existed — a consumer could enforce a
/// limit but never show what it spent.
final class ContextAllocationReportingTests: XCTestCase {
    func testAllocationIsReportedToTheCallback() async {
        let box = AllocationBox()
        let assembler = DefaultContextAssembler(
            onAllocation: { allocation in box.store(allocation) }
        )

        _ = await assembler.assemble(
            systemPrompt: "You are a concise assistant.",
            tools: [
                AnyTool(
                    definition: ToolDefinition(
                        name: "get_weather",
                        description: "Weather for a city.",
                        inputSchema: .object(properties: [:], required: [])
                    ),
                    invoke: { _, _ in .null }
                ),
            ],
            state: AgentState(messages: [.user("hello there")]),
            budget: ContextBudget(total: 4096, reservedForOutput: 512)
        )

        let reported = box.value
        XCTAssertNotNil(reported)
        XCTAssertEqual(reported?.toolsOffered, 1)
        XCTAssertGreaterThan(reported?.toolTokens ?? 0, 0)
        XCTAssertEqual(reported?.budgetAvailable, 3226)
        XCTAssertEqual(
            reported?.selectedToolNames,
            ["get_weather"],
            "Names, not just counts — the debugging question is which tool was offered"
        )
    }

    /// The callback is optional; omitting it must not change anything.
    func testAssemblyWorksWithoutACallback() async {
        let assembler = DefaultContextAssembler()
        let assembled = await assembler.assemble(
            systemPrompt: "System.",
            tools: [],
            state: AgentState(messages: [.user("hi")]),
            budget: ContextBudget(total: 1024)
        )
        XCTAssertGreaterThan(assembled.allocation.totalTokens, 0)
    }

    /// Minimal thread-safe sink; the callback is `@Sendable`.
    private final class AllocationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ContextAllocation?

        var value: ContextAllocation? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.stored
        }

        func store(_ allocation: ContextAllocation) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.stored = allocation
        }
    }
}

// MARK: - ToolFillTests

/// Filling is a fallback for ranking failure, not a supplement to
/// ranking success.
///
/// Two field failures bound this from opposite sides. Sending only
/// lexical matches reduced a twenty-tool surface to a single match on
/// the word "quick", discarding the tool the user needed. Filling
/// unconditionally then sent eight zero-scoring tools alongside a
/// correct match for "Check my fasting status", and the model opened
/// the turn by calling `remember_fact` on a question.
///
/// So the signal that decides is whether ranking produced anything at
/// all: no matches means no information, and everything that fits
/// should ship; matches mean the ranking worked and padding it with
/// tools that scored zero only invites them to be called.
final class ToolFillTests: XCTestCase {
    func testUnmatchedToolsFillRemainingBudget() async {
        let assembler = DefaultContextAssembler()
        let tools = (0..<20).map {
            Self.tool(named: "tool_\($0)", description: "Does specific job number \($0).")
        }

        let assembled = await assembler.assemble(
            systemPrompt: "System.",
            tools: tools,
            // Matches nothing in the corpus.
            state: AgentState(messages: [.user("zzzz")]),
            budget: ContextBudget(total: 8192, maxTools: 12)
        )

        XCTAssertGreaterThan(
            assembled.tools.count,
            1,
            "A budget with room to spare must not ship a near-empty tool set"
        )
        XCTAssertLessThanOrEqual(assembled.tools.count, 12)
    }

    /// When nothing is under pressure, every tool ships untouched and
    /// in registration order.
    ///
    /// Ranking is not run at all here, deliberately. Reordering on a
    /// weak lexical signal is not free: the field failure that
    /// motivated this work put a groceries tool first for a recipe
    /// question on the strength of the word "quick". A stable order
    /// beats a confidently wrong one.
    func testAllToolsShipUnrankedWhenNothingIsUnderPressure() async {
        let assembler = DefaultContextAssembler()
        let tools = [
            Self.tool(named: "rotate_image", description: "Rotate an image."),
            Self.tool(named: "convert_currency", description: "Convert currencies."),
            Self.tool(named: "log_meal", description: "Record a meal the user ate."),
        ]

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("record the meal I ate")]),
            budget: ContextBudget(total: 8192, maxTools: 3)
        )

        XCTAssertEqual(assembled.tools.count, 3)
        XCTAssertEqual(assembled.tools.map(\.name).first, "rotate_image")
    }

    /// Once a limit actually binds, relevance leads — and nothing
    /// irrelevant rides along behind it.
    func testRankedToolsShipWithoutIrrelevantPadding() async {
        let assembler = DefaultContextAssembler()
        var tools = [
            Self.tool(named: "rotate_image", description: "Rotate an image."),
            Self.tool(named: "convert_currency", description: "Convert currencies."),
            Self.tool(named: "log_meal", description: "Record a meal the user ate."),
        ]
        // Push the surface past the cap so selection has to engage.
        tools.append(contentsOf: (0..<10).map {
            Self.tool(named: "filler_\($0)", description: "Unrelated job \($0).")
        })

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("record the meal I ate")]),
            budget: ContextBudget(total: 8192, maxTools: 5)
        )

        XCTAssertEqual(assembled.tools.first?.name, "log_meal", "Relevance leads")
        XCTAssertFalse(
            assembled.tools.contains { $0.name.hasPrefix("filler_") },
            "Spare budget is not a reason to offer tools that scored zero"
        )
    }

    /// The field case, reproduced.
    ///
    /// "Check my fasting status" ranks the fasting tool. It must not
    /// also ship `remember_fact` — the model called it, on a question,
    /// and spent six seconds of an eleven-second time-to-first-token
    /// having the proposal correctly rejected.
    func testACorrectMatchDoesNotDragInUnrelatedTools() async {
        let assembler = DefaultContextAssembler()
        var tools = [
            Self.tool(
                named: "niora__get_fasting_status",
                description: "Whether the user is fasting now, and progress toward their target."
            ),
            Self.tool(named: "remember_fact", description: "Save a durable fact about the user."),
            Self.tool(named: "http_request", description: "Perform an HTTP request to a URL."),
        ]
        tools.append(contentsOf: (0..<20).map {
            Self.tool(named: "other_\($0)", description: "Unrelated capability \($0).")
        })

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("Check my fasting status")]),
            budget: ContextBudget(total: 4096, maxTools: 12)
        )

        let names = assembled.tools.map(\.name)
        XCTAssertTrue(names.contains("niora__get_fasting_status"), "The relevant tool must ship")
        XCTAssertFalse(names.contains("remember_fact"), "A question is not a fact to save")
        XCTAssertFalse(names.contains("http_request"))
    }

    /// The fallback still holds: a query nothing matches must not
    /// collapse the surface to whatever happens to be pinned.
    func testUnrankedQueryStillFillsTheBudget() async {
        let assembler = DefaultContextAssembler()
        let tools = (0..<20).map {
            Self.tool(named: "tool_\($0)", description: "Does specific job number \($0).")
        }

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("zzzz")]),
            budget: ContextBudget(total: 8192, maxTools: 12)
        )

        XCTAssertEqual(assembled.tools.count, 12)
    }

    /// Filling stops at the share ceiling — the pressure the whole
    /// mechanism exists to relieve.
    func testFillRespectsToolShareCeiling() async {
        let assembler = DefaultContextAssembler()
        let tools = (0..<40).map {
            Self.tool(
                named: "tool_\($0)",
                description: String(repeating: "verbose description text ", count: 12)
            )
        }

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("zzzz")]),
            budget: ContextBudget(total: 2000, maxTools: nil, maxToolShare: 0.4)
        )

        let toolTokens = assembled.allocation.toolTokens
        XCTAssertLessThanOrEqual(
            toolTokens,
            Int(Double(assembled.allocation.budgetAvailable) * 0.4) + 50,
            "Tools must not consume more than their share"
        )
        XCTAssertLessThan(assembled.tools.count, 40)
    }

    private static func tool(named name: String, description: String) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: description,
                inputSchema: .object(properties: ["value": .string()], required: [])
            ),
            invoke: { _, _ in .null }
        )
    }
}

// MARK: - AssembledReportingTests

/// Counts answer "how much"; only the text answers "what".
///
/// The prompt the model reads is composed inside the assembler, by
/// folding tool guidance into the caller's prompt — so a consumer
/// cannot reconstruct it from what it passed in. Without this, a
/// diagnostic UI can show totals but not the single thing most often
/// worth seeing.
final class AssembledReportingTests: XCTestCase {
    func testAssembledRequestIsReported() async {
        let box = AssembledBox()
        let assembler = DefaultContextAssembler(
            onAssembled: { assembled in box.store(assembled) }
        )

        _ = await assembler.assemble(
            systemPrompt: "You are concise.",
            tools: [
                AnyTool(
                    definition: ToolDefinition(
                        name: "remember_fact",
                        description: "Store a fact.",
                        inputSchema: .object(properties: [:], required: []),
                        promptGuidance: "Store durable first-person facts."
                    ),
                    invoke: { _, _ in .null }
                ),
            ],
            state: AgentState(messages: [.user("hello")]),
            budget: ContextBudget(total: 4096)
        )

        let reported = box.value
        XCTAssertNotNil(reported)
        let prompt = reported?.messages.first { $0.role == .system }?.textContent ?? ""
        XCTAssertTrue(prompt.contains("You are concise."))
        XCTAssertTrue(
            prompt.contains("Store durable first-person facts."),
            "The composed guidance is exactly what a caller cannot see any other way"
        )
        XCTAssertEqual(reported?.tools.map(\.name), ["remember_fact"])
    }

    private final class AssembledBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AssembledContext?

        var value: AssembledContext? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.stored
        }

        func store(_ assembled: AssembledContext) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.stored = assembled
        }
    }
}

// MARK: - ToolResultBoundingTests

/// Windowing drops whole messages oldest-first and never drops the
/// newest, so it is no defence at all against a tool that returns
/// something enormous.
///
/// The field failure: `simplemcp__get_weather` failed to reach its
/// server, the model responded by calling `load_skill` three times for
/// unrelated skills, each returning a full Markdown body, and the turn
/// died inside FoundationModels with a token-generation error — past
/// the point any budget could see it. Trimming the conversation to
/// nothing would not have helped, because the oversized results *were*
/// the newest messages.
final class ToolResultBoundingTests: XCTestCase {
    /// The crash mechanism, reproduced: results that alone exceed the
    /// window must still assemble to something that fits.
    func testThreeHugeResultsStillFitTheWindow() async {
        let assembler = DefaultContextAssembler()
        let body = String(repeating: "skill guidance text ", count: 800)
        let state = AgentState(messages: [
            .user("What's my current weight?"),
            .tool(callId: "a", text: body),
            .tool(callId: "b", text: body),
            .tool(callId: "c", text: body),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: "You are helpful.",
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        XCTAssertLessThanOrEqual(
            assembled.allocation.totalTokens,
            assembled.allocation.budgetAvailable,
            "A request that exceeds the window is refused by the provider, not truncated"
        )
        XCTAssertEqual(assembled.allocation.toolResultsTruncated, 3)
    }

    /// Truncation is marked. A model handed a fragment it believes is
    /// whole will answer confidently from half a document.
    func testTruncationIsVisibleToTheModel() async {
        let assembler = DefaultContextAssembler()
        let state = AgentState(messages: [
            .user("go"),
            .tool(callId: "a", text: String(repeating: "content ", count: 2000)),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        let toolText = assembled.messages.first { $0.role == .tool }?.textContent ?? ""
        XCTAssertTrue(toolText.contains("truncated"), "The cut must be legible to the model")
        XCTAssertTrue(assembled.allocation.didTruncate)
    }

    /// A result that already fits is passed through untouched — the cap
    /// is a ceiling, not a target.
    func testSmallResultsAreLeftAlone() async {
        let assembler = DefaultContextAssembler()
        let state = AgentState(messages: [
            .user("go"),
            .tool(callId: "a", text: "{\"ok\": true}"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        XCTAssertEqual(assembled.allocation.toolResultsTruncated, 0)
        XCTAssertEqual(
            assembled.messages.first { $0.role == .tool }?.textContent,
            "{\"ok\": true}"
        )
    }

    /// The tool-call id has to survive truncation, or the result stops
    /// resolving against the call that produced it.
    func testTruncationPreservesTheToolCallId() async {
        let assembler = DefaultContextAssembler()
        let state = AgentState(messages: [
            .user("go"),
            .tool(callId: "call-42", text: String(repeating: "x ", count: 4000)),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        XCTAssertEqual(
            assembled.messages.first { $0.role == .tool }?.toolCallId,
            "call-42"
        )
    }
}

// MARK: - InvokedToolScopeTests

/// A tool called on one turn must not lead the ranking on the next.
///
/// Keeping previously-invoked tools available is correct *within* a
/// turn — a tool result the model is still reasoning about needs its
/// tool present or the call becomes unresolvable. Across turns it is a
/// bug: pinned tools bypass ranking and lead the list, so one hydration
/// lookup made `get_hydration_today` the first tool offered for "What
/// about fasting status?" two turns later, and it held a slot on every
/// turn after that.
final class InvokedToolScopeTests: XCTestCase {
    /// The field case: last turn's tool must not outrank this turn's.
    func testPriorTurnsToolDoesNotLeadThisTurn() async {
        let assembler = DefaultContextAssembler()
        var tools = [
            Self.tool("get_hydration_today", "How much water the user has drunk today."),
            Self.tool("get_fasting_status", "Whether the user is fasting now."),
        ]
        tools.append(contentsOf: (0 ..< 15).map {
            Self.tool("other_\($0)", "Unrelated capability \($0).")
        })

        // Turn one asked about water and called the hydration tool;
        // turn two asks about fasting.
        let state = AgentState(messages: [
            .user("how much water did I drink"),
            .assistant("", toolCalls: [ToolCall(id: "1", name: "get_hydration_today", arguments: .object([:]))]),
            .tool(callId: "1", text: "{\"total_ml\": 0}"),
            .user("what about fasting status?"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: state,
            budget: ContextBudget(total: 4096, maxTools: 6)
        )

        XCTAssertEqual(
            assembled.tools.first?.name,
            "get_fasting_status",
            "This turn's subject leads, not last turn's tool"
        )
    }

    /// The behaviour being scoped, not removed: mid-turn, a tool whose
    /// result is still in play stays available.
    func testToolStaysAvailableWithinTheSameTurn() async {
        let assembler = DefaultContextAssembler()
        var tools = [Self.tool("get_hydration_today", "How much water the user has drunk today.")]
        tools.append(contentsOf: (0 ..< 15).map {
            Self.tool("other_\($0)", "Unrelated capability \($0).")
        })

        // No new user message after the call — still the same turn.
        let state = AgentState(messages: [
            .user("zzzz qqqq"),
            .assistant("", toolCalls: [ToolCall(id: "1", name: "get_hydration_today", arguments: .object([:]))]),
            .tool(callId: "1", text: "{\"total_ml\": 0}"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: state,
            budget: ContextBudget(total: 4096, maxTools: 6)
        )

        XCTAssertTrue(
            assembled.tools.contains { $0.name == "get_hydration_today" },
            "A result still being reasoned about needs its tool present"
        )
    }

    private static func tool(_ name: String, _ description: String) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: description,
                inputSchema: .object(properties: [:], required: [])
            ),
            invoke: { _, _ in .null }
        )
    }
}

// MARK: - PastReasoningTests

/// A thinking model's scratchpad is for the turn that produced it.
///
/// Chat templates already discard it — LFM2's strips every assistant
/// block but the last. Budgeting against it anyway is worse than
/// wasteful: real messages get dropped to make room for text the
/// template then throws away. Observed on LFM2.5 Thinking as 1,980
/// tokens of history and four dropped messages across five short
/// exchanges.
final class PastReasoningTests: XCTestCase {
    func testPastTurnsReasoningIsNotBudgeted() async {
        let assembler = DefaultContextAssembler()
        let thinking = "<think>" + String(repeating: "deliberating ", count: 400) + "</think>Yes."
        let state = AgentState(messages: [
            .user("how's my fasting?"),
            .assistant(thinking),
            .user("what about water?"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        let history = assembled.messages.map(\.textContent).joined()
        XCTAssertFalse(history.contains("deliberating"), "Past reasoning must not be budgeted")
        XCTAssertTrue(history.contains("Yes."), "The answer it produced still matters")
    }

    /// The current turn keeps its scratchpad — a step that loses its
    /// own working-out starts over.
    func testCurrentTurnKeepsItsReasoning() async {
        let assembler = DefaultContextAssembler()
        let state = AgentState(messages: [
            .user("how's my fasting?"),
            .assistant("<think>still working</think>"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        XCTAssertTrue(
            assembled.messages.map(\.textContent).joined().contains("still working")
        )
    }

    /// A stream cut mid-thought would otherwise leave the whole
    /// remainder in place — the oversized case this exists to prevent.
    func testUnterminatedReasoningIsStillRemoved() async {
        let assembler = DefaultContextAssembler()
        let state = AgentState(messages: [
            .user("first"),
            .assistant("<think>" + String(repeating: "cut off ", count: 400)),
            .user("second"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        XCTAssertFalse(assembled.messages.map(\.textContent).joined().contains("cut off"))
    }

    /// Messages without reasoning pass through untouched.
    @MainActor
    func testOrdinaryMessagesAreUnchanged() async {
        let assembler = DefaultContextAssembler()
        let state = AgentState(messages: [
            .user("first"),
            .assistant("A plain answer."),
            .user("second"),
        ])

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: [],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768)
        )

        XCTAssertTrue(assembled.messages.map(\.textContent).joined().contains("A plain answer."))
    }
}

// MARK: - UnrankedFillTests

/// How much to read into "nothing scored" depends on the ranker.
///
/// Filling to the cap is the right hedge for a ranker that misses. It
/// is wrong for one that doesn't: told "I live in Dublin, CA", a model
/// was handed `http_request`, `base64_codec`, `start_fast` and
/// `log_water` — none related to anything — and answered by inventing a
/// call to a weather API, then spent two more turns apologising for the
/// weather.
final class UnrankedFillTests: XCTestCase {
    /// A zero limit means an unmatched query gets only what was pinned.
    func testZeroLimitSendsNothingUnranked() async {
        let assembler = DefaultContextAssembler(unrankedFillLimit: 0)
        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: Self.tools(),
            state: AgentState(messages: [.user("zzzz qqqq")]),
            budget: ContextBudget(total: 8192, maxTools: 6)
        )
        XCTAssertTrue(assembled.tools.isEmpty, "Nothing matched, so nothing is offered")
    }

    /// Pinned tools are not filler and survive regardless.
    func testPinnedToolsSurviveAZeroLimit() async {
        let assembler = DefaultContextAssembler(
            pinnedToolNames: ["load_skill"],
            unrankedFillLimit: 0
        )
        var tools = Self.tools()
        tools.append(Self.tool("load_skill", "Load a named skill's instructions."))

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("zzzz qqqq")]),
            budget: ContextBudget(total: 8192, maxTools: 6)
        )
        XCTAssertEqual(assembled.tools.map(\.name), ["load_skill"])
    }

    /// A small limit hedges without flooding.
    func testSmallLimitCapsTheFiller() async {
        let assembler = DefaultContextAssembler(unrankedFillLimit: 2)
        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: Self.tools(),
            state: AgentState(messages: [.user("zzzz qqqq")]),
            budget: ContextBudget(total: 8192, maxTools: 6)
        )
        XCTAssertEqual(assembled.tools.count, 2)
    }

    /// The default is unchanged, so consumers that never opt in keep
    /// the old hedge.
    func testDefaultStillFillsToTheCap() async {
        let assembler = DefaultContextAssembler()
        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: Self.tools(),
            state: AgentState(messages: [.user("zzzz qqqq")]),
            budget: ContextBudget(total: 8192, maxTools: 6)
        )
        XCTAssertEqual(assembled.tools.count, 6)
    }

    /// A limit governs only the unranked path — a query that matches
    /// still gets its matches.
    func testRankedToolsAreUnaffected() async {
        let assembler = DefaultContextAssembler(unrankedFillLimit: 0)
        var tools = Self.tools()
        tools.append(Self.tool("log_meal", "Record a meal the user ate."))

        let assembled = await assembler.assemble(
            systemPrompt: nil,
            tools: tools,
            state: AgentState(messages: [.user("record the meal I ate")]),
            budget: ContextBudget(total: 8192, maxTools: 6)
        )
        XCTAssertEqual(assembled.tools.first?.name, "log_meal")
    }

    private static func tools() -> [AnyTool] {
        (0 ..< 12).map { Self.tool("tool_\($0)", "Does specific job number \($0).") }
    }

    private static func tool(_ name: String, _ description: String) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: description,
                inputSchema: .object(properties: ["value": .string()], required: [])
            ),
            invoke: { _, _ in .null }
        )
    }
}
