import Foundation

// MARK: - ParsedAssistantContent

/// What the chat actually wants to render for an assistant turn,
/// split out of the raw model + middleware-injected text so the
/// bubble can show structure (thinking pill, recall chip, tool
/// pills) instead of inline noise like `[recalled: …]` or
/// `<think>…</think>`.
struct ParsedAssistantContent: Equatable {
    /// The user-visible message body. `<think>` blocks stripped,
    /// `[calling toolname]` inline badges stripped, `[recalled: …]`
    /// brackets stripped. Empty until the first non-thinking token
    /// arrives.
    var visible: String

    /// Concatenated content of any `<think>…</think>` blocks the
    /// model emitted. Nil when none. Shown above the bubble as a
    /// collapsed "Thought for …" pill.
    var thinking: String?

    /// `true` while the model is still actively reasoning — opening
    /// `<think>` seen but no closing `</think>` yet, OR the model
    /// is implicitly thinking (e.g. Qwen 3.5 streams reasoning text
    /// without an opening tag) and `</think>` hasn't arrived.
    /// Drives the "Thinking…" active pill in the bubble.
    var thinkingInProgress: Bool

    /// Names of tools the agent emitted `.toolCallRequested` for
    /// during this turn. Rendered as small pills above the bubble.
    var toolCalls: [String]

    /// Memory items `RAGMiddleware.onRecall` surfaced for this turn.
    /// Rendered as a single "Recalled N memories" pill.
    var recalledMemories: [String]
}

// MARK: - MessageContentParser

/// Pure parser. Takes the raw streamed assistant text + the per-turn
/// metadata the chat layer has collected (tool-call names + RAG
/// recall) and produces the `ParsedAssistantContent` the bubble
/// renders. Stateless, deterministic, tested in isolation.
///
/// Why parse at display time instead of stripping when we collect:
/// the streamed text can be PARTIAL on every render — a `<think>`
/// opens on one yield, more content arrives, then `</think>` arrives
/// later. Stripping eagerly would lose the open bracket and miss
/// content; parsing on each render handles partial inputs cleanly.
enum MessageContentParser {
    // MARK: Internal

    /// Parse the accumulated raw text + metadata for one turn.
    ///
    /// `expectsThinking` is the chat layer's hint that this turn
    /// comes from a reasoning model (Qwen 3.x, DeepSeek R1, etc.)
    /// that streams its reasoning *without* an opening `<think>`
    /// tag. When set, mid-stream text with no `</think>` yet is
    /// treated as thinking content, not visible output — so the
    /// reasoning doesn't leak into the bubble before the model
    /// transitions to its real reply.
    static func parse(
        raw: String,
        toolCalls: [String] = [],
        recalledMemories: [String] = [],
        expectsThinking: Bool = false
    ) -> ParsedAssistantContent {
        var thinking: String?
        var thinkingInProgress = false
        var visible = raw

        // 1. Extract every <think>…</think> block. Partial blocks
        //    (opened but not yet closed) hide everything from the
        //    open tag forward — the model is still reasoning and
        //    nothing user-facing has arrived yet.
        if let openRange = visible.range(of: Self.thinkOpen) {
            var accumulated: [String] = []
            var cursor = openRange.lowerBound
            var rest = visible[openRange.upperBound...]
            while let close = rest.range(of: Self.thinkClose) {
                let block = rest[..<close.lowerBound]
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    accumulated.append(trimmed)
                }
                // Replace the entire `<think>…</think>` (including
                // tags) with empty in the visible text.
                let absoluteCloseEnd = rest.index(after: close.upperBound) <= rest.endIndex
                    ? close.upperBound
                    : rest.endIndex
                rest = rest[absoluteCloseEnd...]
                cursor = visible.index(cursor, offsetBy: visible.distance(from: cursor, to: absoluteCloseEnd))
                // Re-scan from cursor for another open tag.
                if let nextOpen = rest.range(of: Self.thinkOpen) {
                    let prefix = rest[..<nextOpen.lowerBound]
                    visible = String(visible[..<cursor]) + String(prefix)
                    rest = rest[nextOpen.upperBound...]
                } else {
                    visible = String(visible[..<cursor]) + String(rest)
                    rest = ""
                    break
                }
            }
            // Unclosed `<think>` at end of stream: hide everything
            // from the open tag forward.
            if rest.isEmpty == false, visible.range(of: Self.thinkOpen) != nil {
                // Still mid-thinking — strip from open tag onward.
                if let stillOpen = visible.range(of: Self.thinkOpen) {
                    let partial = String(visible[stillOpen.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty {
                        accumulated.append(partial)
                    }
                    visible = String(visible[..<stillOpen.lowerBound])
                    thinkingInProgress = true
                }
            }
            thinking = accumulated.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if thinking?.isEmpty == true {
                thinking = nil
            }
        }

        // 1b. **Implicit thinking** — Qwen 3.x and other reasoning
        //     models stream their reasoning *without* an opening
        //     `<think>` tag, then close it with `</think>` once
        //     they're ready to answer. Two cases:
        //       a) `</think>` already seen → split: everything
        //          before is thinking, everything after is visible.
        //       b) `</think>` not yet → and `expectsThinking == true`
        //          (reasoning model in flight): treat the whole
        //          accumulated text as thinking-in-progress.
        if thinking == nil {
            if let closeRange = visible.range(of: Self.thinkClose) {
                let before = String(visible[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let after = String(visible[closeRange.upperBound...])
                if !before.isEmpty {
                    thinking = before
                }
                visible = after
            } else if expectsThinking, !visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                thinking = visible.trimmingCharacters(in: .whitespacesAndNewlines)
                visible = ""
                thinkingInProgress = true
            }
        }

        // 2. Strip `[calling toolname]` inline badges — they're
        //    redundant with the tool pills we render above the
        //    bubble. Matches both `[calling foo]` and the same
        //    surrounded by whitespace.
        visible = visible.replacingOccurrences(
            of: #"\s*\[calling [^\]]+\]\s*"#,
            with: " ",
            options: .regularExpression
        )

        // 3. Strip a leading `[recalled: …]` bracket — old chat
        //    history written by an earlier version of the sample
        //    that prepended recall results into the message body.
        //    New turns never emit this; this is migration noise.
        visible = visible.replacingOccurrences(
            of: #"^\s*\[recalled:[^\]]+\]\s*"#,
            with: "",
            options: .regularExpression
        )

        // 4. Strip Llama-family chat-template tokens that the
        //    SDK's tool-call parser sometimes doesn't intercept,
        //    leaking into the visible text:
        //      `<|python_tag|>{"id":"…","stored":true}`
        //      `<|eom_id|>`, `<|eot_id|>`, `<|start_header_id|>…<|end_header_id|>`
        //    These are model-internal control sequences; users
        //    shouldn't see them either way.
        let templateTokenPatterns = [
            #"<\|python_tag\|>"#,
            #"<\|eom_id\|>"#,
            #"<\|eot_id\|>"#,
            #"<\|start_header_id\|>[\s\S]*?<\|end_header_id\|>"#,
            #"<\|begin_of_text\|>"#,
            #"<\|end_of_text\|>"#,
            #"<\|reserved_special_token_\d+\|>"#,
            #"<\|im_start\|>[\s\S]*?<\|im_end\|>"#,
            #"<\|im_start\|>"#,
            #"<\|im_end\|>"#,
        ]
        for pattern in templateTokenPatterns {
            visible = visible.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        // 5. Strip orphaned `{"id":"…","stored":true}` blobs that
        //    immediately follow a tool-result emission. They're the
        //    JSON the `remember_fact` tool returned, which the model
        //    sometimes echoes when the tool-call parser misses it.
        visible = visible.replacingOccurrences(
            of: #"\s*\{\s*"id"\s*:\s*"[A-F0-9-]+"\s*,\s*"stored"\s*:\s*(?:true|false)\s*\}\s*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        // 6. Final cleanup — collapse whitespace runs left behind by
        //    the strip steps; trim outer whitespace.
        visible = visible
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedAssistantContent(
            visible: visible,
            thinking: thinking,
            thinkingInProgress: thinkingInProgress,
            toolCalls: toolCalls,
            recalledMemories: recalledMemories
        )
    }

    // MARK: Private

    private static let thinkOpen = "<think>"
    private static let thinkClose = "</think>"
}
