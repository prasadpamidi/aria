import Foundation
import XCTest
@testable import Aria
import AriaTesting

// MARK: - TieredLLMProviderTests

final class TieredLLMProviderTests: XCTestCase {
    // MARK: - Escalation triggers

    func testEmptyFirstTierEscalates() async throws {
        let weak = MockLLMProvider(scenes: [.init([.messageStop(.endTurn)])])
        let strong = MockLLMProvider(scenes: [.text("a real answer")])
        let tiered = TieredLLMProvider(tiers: [weak, strong])

        let events = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [],
            options: .init()
        ))

        XCTAssertEqual(strong.invocations.count, 1, "The stronger tier should have run")
        XCTAssertTrue(Self.text(in: events).contains("a real answer"))
    }

    func testWhitespaceOnlyOutputCountsAsEmpty() async throws {
        let weak = MockLLMProvider(scenes: [.init([.textDelta("  \n "), .messageStop(.endTurn)])])
        let strong = MockLLMProvider(scenes: [.text("real")])
        let tiered = TieredLLMProvider(tiers: [weak, strong])

        _ = try await self.collect(tiered.stream(messages: [.user("hi")], tools: [], options: .init()))

        XCTAssertEqual(
            strong.invocations.count,
            1,
            "A newline is not something the user can read; the window must stay open"
        )
    }

    func testThrowingFirstTierEscalates() async throws {
        // Out of scenes makes the mock throw.
        let weak = MockLLMProvider(scenes: [])
        let strong = MockLLMProvider(scenes: [.text("recovered")])
        let tiered = TieredLLMProvider(tiers: [weak, strong])

        let events = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [],
            options: .init()
        ))

        XCTAssertEqual(strong.invocations.count, 1)
        XCTAssertTrue(Self.text(in: events).contains("recovered"))
    }

    /// Small models invent tool names. The call cannot be dispatched, so
    /// the turn is lost either way — retrying costs only latency.
    func testUnknownToolCallEscalates() async throws {
        let bogus = ToolCall(id: "1", name: "not_a_real_tool", arguments: .object([:]))
        let weak = MockLLMProvider(scenes: [.init([.toolCallStart(bogus), .messageStop(.toolUse)])])
        let strong = MockLLMProvider(scenes: [.text("fallback")])
        let tiered = TieredLLMProvider(tiers: [weak, strong])

        _ = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [Self.definition("real_tool")],
            options: .init()
        ))

        XCTAssertEqual(strong.invocations.count, 1)
    }

    func testKnownToolCallDoesNotEscalate() async throws {
        let good = ToolCall(id: "1", name: "real_tool", arguments: .object([:]))
        let weak = MockLLMProvider(scenes: [.init([.toolCallStart(good), .messageStop(.toolUse)])])
        let strong = MockLLMProvider(scenes: [.text("should not run")])
        let tiered = TieredLLMProvider(tiers: [weak, strong])

        _ = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [Self.definition("real_tool")],
            options: .init()
        ))

        XCTAssertEqual(strong.invocations.count, 0, "A valid tool call is a success, not a failure")
    }

    // MARK: - The streaming boundary

    /// The property the whole design rests on: once text is on screen,
    /// the attempt is final. Retrying would retract words already read.
    func testVisibleOutputCommitsToTheTierEvenIfItLaterFails() async throws {
        let weak = MockLLMProvider(scenes: [.init([
            .textDelta("partial answer"),
            // No messageStop; the mock ends the scene here.
        ])])
        let strong = MockLLMProvider(scenes: [.text("replacement")])
        let tiered = TieredLLMProvider(tiers: [weak, strong])

        let events = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [],
            options: .init()
        ))

        XCTAssertEqual(strong.invocations.count, 0, "Committed tiers must never be retried")
        XCTAssertTrue(Self.text(in: events).contains("partial answer"))
        XCTAssertFalse(Self.text(in: events).contains("replacement"))
    }

    func testSuccessfulFirstTierNeverInvokesTheSecond() async throws {
        let weak = MockLLMProvider(scenes: [.text("good enough")])
        let strong = MockLLMProvider(scenes: [.text("unused")])
        let tiered = TieredLLMProvider(tiers: [weak, strong])

        _ = try await self.collect(tiered.stream(messages: [.user("hi")], tools: [], options: .init()))

        XCTAssertEqual(strong.invocations.count, 0)
    }

    /// Buffered events must reach the consumer in their original order,
    /// or a tool call could arrive before the message it belongs to.
    func testBufferedEventsArriveInOrder() async throws {
        let weak = MockLLMProvider(scenes: [.init([
            .messageStart(messageId: "m1"),
            .textDelta("one "),
            .textDelta("two"),
            .messageStop(.endTurn),
        ])])
        let tiered = TieredLLMProvider(tiers: [weak])

        let events = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [],
            options: .init()
        ))

        XCTAssertEqual(Self.text(in: events), "one two")
        if case .messageStart = events.first {} else {
            XCTFail("messageStart must still arrive first")
        }
    }

    // MARK: - validateBeforeYield

    /// With no UI attached there is no partial output to protect, so
    /// full validation is strictly better than the streaming boundary.
    func testValidateBeforeYieldEscalatesDespiteVisibleText() async throws {
        let bogus = ToolCall(id: "1", name: "ghost_tool", arguments: .object([:]))
        let weak = MockLLMProvider(scenes: [.init([
            .textDelta("here you go"),
            .toolCallStart(bogus),
            .messageStop(.toolUse),
        ])])
        let strong = MockLLMProvider(scenes: [.text("validated answer")])
        let tiered = TieredLLMProvider(
            tiers: [weak, strong],
            validateBeforeYield: true
        )

        let events = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [Self.definition("real_tool")],
            options: .init()
        ))

        XCTAssertEqual(strong.invocations.count, 1)
        XCTAssertFalse(
            Self.text(in: events).contains("here you go"),
            "Buffered mode must not leak the abandoned attempt"
        )
    }

    // MARK: - Capabilities and shape

    /// Identity is the primary's — this is that model with fallbacks,
    /// not a different model.
    func testIdentityComesFromTheFirstTier() {
        let tiered = TieredLLMProvider(tiers: [
            MockLLMProvider(
                scenes: [.text("x")],
                capabilities: ProviderCapabilities(modelIdentifier: "small", usableContextTokens: 4096)
            ),
            MockLLMProvider(
                scenes: [.text("y")],
                capabilities: ProviderCapabilities(modelIdentifier: "large", usableContextTokens: 128_000)
            ),
        ])
        XCTAssertEqual(tiered.capabilities.modelIdentifier, "small")
    }

    /// A request is assembled once and may go to any tier, so it must
    /// fit the smallest window — not tier 0's.
    ///
    /// Ladders are ordered by capability, and capability does not
    /// imply context length. Apple's on-device model is the case that
    /// broke the original assumption: stronger than a 1.2B, with a
    /// 4,096 window against that model's 6,144. Budgeting for tier 0
    /// produced `exceededContextWindowSize` on escalation.
    func testContextWindowIsTheSmallestAcrossTiers() {
        let tiered = TieredLLMProvider(tiers: [
            MockLLMProvider(
                scenes: [.text("x")],
                capabilities: ProviderCapabilities(modelIdentifier: "roomy", usableContextTokens: 6144)
            ),
            MockLLMProvider(
                scenes: [.text("y")],
                capabilities: ProviderCapabilities(modelIdentifier: "cramped", usableContextTokens: 4096)
            ),
        ])
        XCTAssertEqual(
            tiered.capabilities.usableContextTokens,
            4096,
            "Escalating upward in capability can move downward in context"
        )
    }

    /// A feature only one tier supports cannot be relied on.
    func testFeatureFlagsAreIntersected() {
        let tiered = TieredLLMProvider(tiers: [
            MockLLMProvider(
                scenes: [.text("x")],
                capabilities: ProviderCapabilities(
                    modelIdentifier: "visionary",
                    supportsToolUse: true,
                    supportsVision: true
                )
            ),
            MockLLMProvider(
                scenes: [.text("y")],
                capabilities: ProviderCapabilities(
                    modelIdentifier: "text-only",
                    supportsToolUse: true,
                    supportsVision: false
                )
            ),
        ])
        XCTAssertTrue(tiered.capabilities.supportsToolUse, "Both support tools")
        XCTAssertFalse(tiered.capabilities.supportsVision, "Only one supports vision")
    }

    /// `nil` means "unstated", not "unlimited" — such a tier cannot
    /// constrain a bound it never declared.
    func testUndeclaredWindowsDoNotConstrain() {
        let tiered = TieredLLMProvider(tiers: [
            MockLLMProvider(
                scenes: [.text("x")],
                capabilities: ProviderCapabilities(modelIdentifier: "known", usableContextTokens: 4096)
            ),
            MockLLMProvider(
                scenes: [.text("y")],
                capabilities: ProviderCapabilities(modelIdentifier: "unknown")
            ),
        ])
        XCTAssertEqual(tiered.capabilities.usableContextTokens, 4096)
    }

    func testSingleTierBehavesLikeThatProvider() async throws {
        let only = MockLLMProvider(scenes: [.text("solo")])
        let tiered = TieredLLMProvider(tiers: [only])

        let events = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [],
            options: .init()
        ))
        XCTAssertEqual(Self.text(in: events), "solo")
    }

    /// The last tier's output stands even when it also failed — there
    /// is nothing better to try, and swallowing it would lose the turn.
    func testFinalTierFailureIsSurfacedRatherThanSwallowed() async throws {
        let weak = MockLLMProvider(scenes: [.init([.messageStop(.endTurn)])])
        let alsoWeak = MockLLMProvider(scenes: [.init([.messageStop(.endTurn)])])
        let tiered = TieredLLMProvider(tiers: [weak, alsoWeak])

        let events = try await self.collect(tiered.stream(
            messages: [.user("hi")],
            tools: [],
            options: .init()
        ))

        XCTAssertEqual(alsoWeak.invocations.count, 1)
        XCTAssertFalse(events.isEmpty, "The final attempt's events must still be delivered")
    }

    // MARK: - Diagnostics

    /// Escalation rate is the signal that a default model is wrong.
    func testEscalationIsReported() async throws {
        let box = OutcomeBox()
        let weak = MockLLMProvider(scenes: [.init([.messageStop(.endTurn)])])
        let strong = MockLLMProvider(scenes: [.text("answer")])
        let tiered = TieredLLMProvider(
            tiers: [weak, strong],
            onEscalation: { outcome in box.store(outcome) }
        )

        _ = try await self.collect(tiered.stream(messages: [.user("hi")], tools: [], options: .init()))

        XCTAssertEqual(box.value?.tierIndex, 0)
        XCTAssertTrue(box.value?.isEmpty ?? false)
    }

    // MARK: - Helpers

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AttemptOutcome?

        var value: AttemptOutcome? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.stored
        }

        func store(_ outcome: AttemptOutcome) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.stored = outcome
        }
    }

    private static func definition(_ name: String) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: "A tool.",
            inputSchema: .object(properties: [:], required: [])
        )
    }

    private static func text(in events: [ProviderEvent]) -> String {
        events.compactMap { event in
            if case let .textDelta(chunk) = event { chunk } else { nil }
        }.joined()
    }

    private func collect(
        _ stream: AsyncThrowingStream<ProviderEvent, any Error>
    ) async throws -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        do {
            for try await event in stream {
                events.append(event)
            }
        } catch {
            // Terminal errors are part of the outcome under test; the
            // events collected so far are what matters.
        }
        return events
    }
}
