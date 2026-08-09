#if ARIA_MLX
    import Aria
    import AriaMLX
    import XCTest

    // MARK: - LFM2ToolEmissionProbeTests

    /// Does LFM2.5 actually emit a tool call?
    ///
    /// Four rounds of reasoning about this code produced four plausible
    /// theories — the template, the tool specs, the catalog flags, the
    /// detokenizer — and every one of them checked out on inspection.
    /// The tools reach the model (its own reasoning trace names them),
    /// `mlx-swift-lm` preserves special tokens by default, and the
    /// `.toolCall` event path is wired.
    ///
    /// What has never been observed is the token stream itself. This
    /// prints it verbatim, which is the only thing that separates "the
    /// model never emitted a call" from "it emitted one we failed to
    /// parse" — and those have opposite fixes.
    ///
    ///     TEST_RUNNER_ARIA_RUN_EVALS=1 xcodebuild test \
    ///       -scheme Aria-Package -destination 'platform=macOS,arch=arm64' \
    ///       -only-testing:AriaMLXTests/LFM2ToolEmissionProbeTests \
    ///       -skipPackagePluginValidation -skipMacroValidation
    final class LFM2ToolEmissionProbeTests: XCTestCase {
        func testWhatLFM2EmitsWhenAToolWouldAnswer() async throws {
            try XCTSkipUnless(
                ProcessInfo.processInfo.environment["ARIA_RUN_EVALS"] == "1",
                "Downloads LFM2.5-1.2B; set ARIA_RUN_EVALS=1"
            )

            let capabilities = try XCTUnwrap(
                MLXModelCatalog.defaults.first { $0.id.contains("LFM2.5-1.2B-Instruct") },
                "LFM2.5 1.2B Instruct missing from the catalog"
            )
            // The clause Avyra shipped, and the replacement.
            let prompts = [
                ("BARE-none", ""),
                ("BARE-generic", "You are a concise assistant."),
                ("AVYRA-no-tool-clause", "You are Avyra, a concise, helpful assistant."),
                (
                    "OLD",
                    "You are Avyra, a concise, helpful assistant.\n\nAlways use the tools you have access to when they are relevant; never describe a tool call in your reply text."
                ),
                (
                    "NEW",
                    "You are Avyra, a concise, helpful assistant.\n\nWhen a tool can answer part of the request, call it and use its result. Never write out a value a tool would have returned, and never leave a placeholder in your reply."
                ),
                // Candidate: says nothing about *how* to call a tool —
                // the failure mode of OLD and NEW — and only about what
                // may be claimed afterwards.
                (
                    "GROUNDING",
                    """
                    You are Avyra, a concise, helpful assistant.

                    State only what the conversation or a tool result actually says. \
                    If a tool fails or returns nothing, say so plainly rather than \
                    filling the gap. If a tool needs a value you were not given, ask \
                    for it — never invent one, and never leave a placeholder in a reply.
                    """
                ),
            ]
            let store = MLXModelStore()

            let clock = AnyTool(
                definition: ToolDefinition(
                    name: "current_time",
                    description: "Get the current date and time in the user's timezone.",
                    inputSchema: .object(properties: [:], required: [])
                ),
                invoke: { _, _ in .object(["iso8601": .string("2026-08-08T00:00:00Z")]) }
            )

            for (label, prompt) in prompts {
                let provider = MLXProvider(
                    capabilities: capabilities,
                    store: store,
                    defaultInstructions: prompt
                )
                var text = ""
                var toolCalls: [String] = []
                for try await event in provider.stream(
                    messages: [.user("What time is it right now?")],
                    executableTools: [clock],
                    options: .init()
                ) {
                    switch event {
                    case let .textDelta(delta): text += delta
                    case let .toolCallStart(call): toolCalls.append(call.name)
                    default: break
                    }
                }
                print("PROMPT-\(label) calls=\(toolCalls) text=\(text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            }
        }
    }
#endif
