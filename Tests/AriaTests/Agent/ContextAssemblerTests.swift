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
        XCTAssertEqual(allocation.budgetAvailable, 3584)
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
        XCTAssertEqual(reported?.budgetAvailable, 3584)
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
