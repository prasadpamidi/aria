import Foundation

// MARK: - ToolFailure

/// What the model is told when a tool call fails.
///
/// A bare error string reads to a small model as "that route didn't
/// work, try another one." Observed, in one turn: asked how much water
/// the user drank, the agent called the right tool, got
/// `Authentication required` back, and then called an unrelated skill,
/// a URL codec, and a calculator with the literal expression `2000` —
/// finally answering "You drank 2000ml of water today."
///
/// Every step of that is a reasonable-looking local decision. The tool
/// failed, so try something else; a number is needed, so compute one;
/// a result exists, so report it. What was missing is the one thing a
/// bare error never says: **that failing to answer is an acceptable
/// outcome, and inventing an answer is not.**
///
/// So the guidance travels with the failure rather than living in the
/// system prompt. It costs nothing on turns where nothing fails, it is
/// adjacent to the decision it governs — which matters on models that
/// weight nearby text far above distant instructions — and it cannot
/// drift out of sync with a tool policy written somewhere else.
public enum ToolFailure {
    /// Appended to a failed tool's result before the model reads it.
    ///
    /// Phrased as what to *do*, not what to avoid. "Don't hallucinate"
    /// names a behaviour the model does not believe it is performing;
    /// "tell the user the tool failed" names an action it can take.
    public static let guidance = """
    This tool call FAILED and returned no usable data. Tell the user \
    plainly that it failed and what the error was. Do not substitute a \
    value you assembled yourself, and do not call other tools to \
    produce one — a failure reported honestly is a correct answer here, \
    and a number that did not come from the tool is not.
    """

    /// Render a result for the model, appending guidance on failure.
    public static func render(_ result: ToolExecutionResult) -> String {
        let body: String =
            if let data = try? result.output.canonicalData(),
            let string = String(data: data, encoding: .utf8) {
                string
            } else {
                result.isError ? "(tool error)" : "(tool output)"
            }
        guard result.isError else {
            return body
        }
        return "\(body)\n\n\(Self.guidance)"
    }
}
