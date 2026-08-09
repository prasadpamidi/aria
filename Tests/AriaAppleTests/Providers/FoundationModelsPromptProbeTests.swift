#if canImport(FoundationModels)
    import Aria
    @testable import AriaApple
    import FoundationModels
    import XCTest

    // MARK: - FoundationModelsPromptProbeTests

    /// Does a longer system prompt cost FoundationModels its tool calls?
    ///
    /// On LFM2.5-1.2B it does, for any prompt beyond a persona line —
    /// measured across tool-mechanics wording, a rewrite of it, and
    /// pure output-grounding instructions. All three suppressed the
    /// call and produced an invented timestamp.
    ///
    /// That constraint was then applied to every model, which is a
    /// generalisation from one 1.2B model to a 3B one that was never
    /// tested — and the field failures being reasoned about
    /// (misreading a tool result, inventing an API key) were all on
    /// this provider, not that one.
    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsPromptProbeTests: XCTestCase {
        override func setUpWithError() throws {
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw XCTSkip("Requires iOS 26 / macOS 26 runtime")
            }
            try XCTSkipUnless(
                SystemLanguageModel.default.isAvailable,
                "Requires an available on-device model"
            )
        }

        func testPromptLengthAgainstToolCalling() async throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["ARIA_RUN_EVALS"] == "1",
                "Runs a real model; set ARIA_RUN_EVALS=1"
            )
            do {
                try FoundationModelsProvider.checkAvailability()
            } catch {
                throw XCTSkip("Apple Intelligence unavailable: \(error)")
            }

            for (label, prompt) in Self.prompts {
                let provider = FoundationModelsProvider(
                    defaultInstructions: prompt,
                    typedTools: [{ _ in ClockTool() }]
                )
                var text = ""
                var calls: [String] = []
                for try await event in provider.stream(
                    messages: [.system(prompt), .user("What time is it right now?")],
                    executableTools: [Self.clockDefinition],
                    options: .init()
                ) {
                    switch event {
                    case let .textDelta(delta): text += delta
                    case let .toolCallExecuted(call, _): calls.append(call.name)
                    default: break
                    }
                }
                let flat = text.replacingOccurrences(of: "\n", with: " ")
                print("FM-\(label) calls=\(calls) text=\(flat.prefix(120))")
            }
        }

        // MARK: Fixtures

        private static let prompts: [(String, String)] = [
            ("persona-only", "You are Avyra, a concise, helpful assistant."),
            (
                "grounding",
                """
                You are Avyra, a concise, helpful assistant.

                State only what the conversation or a tool result actually says. If a \
                tool fails or returns nothing, say so plainly rather than filling the \
                gap. If a tool needs a value you were not given, ask for it — never \
                invent one, and never leave a placeholder in a reply.
                """
            ),
        ]

        private static let clockDefinition = AnyTool(
            definition: ToolDefinition(
                name: "current_time",
                description: "Get the current date and time in the user's timezone.",
                inputSchema: .object(properties: [:], required: [])
            ),
            invoke: { _, _ in .object(["iso8601": .string("2026-08-09T04:00:00Z")]) }
        )
    }

    // MARK: - ClockTool

    @available(iOS 26.0, macOS 26.0, *)
    private struct ClockTool: FoundationModels.Tool {
        @Generable
        struct Arguments: Codable {
            @Guide(description: "Unused.")
            var unused: String
        }

        typealias Output = String

        let name = "current_time"
        let description = "Get the current date and time in the user's timezone."

        func call(arguments _: Arguments) async throws -> String {
            "{\"iso8601\": \"2026-08-09T04:00:00Z\"}"
        }
    }
#endif
