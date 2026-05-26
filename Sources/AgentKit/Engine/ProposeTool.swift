import Aria
import Foundation

#if canImport(FoundationModels)
    import AriaApple
    import FoundationModels
#endif

#if canImport(FoundationModels)

    // MARK: - ProposeActionArguments

    /// Typed arguments for the `propose_action` tool. A fixed shape, so
    /// it can be a real `@Generable` `GenerableTool.Input` (unlike the
    /// dynamic capability/MCP tools that wrap a free-form
    /// `argumentsJSON`).
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct ProposeActionArguments: Codable {
        @Guide(
            description: "Action kind, e.g. send_email or create_event. Must be one of the allowed kinds named in this tool's description."
        )
        var kind: String

        @Guide(description: "Short, human-readable headline for the user's approval card.")
        var title: String

        @Guide(
            description: "Longer detail the user should review before approving — e.g. the full drafted email body. Use an empty string when there's nothing extra to show."
        )
        var detail: String

        @Guide(
            description: "The action's arguments as a JSON object string the host will execute verbatim on approval. Example: {\"to\":\"a@b.com\",\"subject\":\"Hi\",\"body\":\"…\"}."
        )
        var payloadJSON: String
    }

    // MARK: - ProposeTool

    /// The safe half of the human-in-the-loop design: a trust-critical
    /// agent gets this tool INSTEAD of any side-effecting tool. Calling
    /// it records a structured `AgentProposal` into the run's
    /// `AgentApprovalSink` and returns a "stop and wait" message — it
    /// never performs the side effect. The host runs the real action
    /// only after the user approves, so a re-run can't double-fire.
    @available(iOS 26.0, macOS 26.0, *)
    struct ProposeTool: GenerableTool {
        // MARK: Lifecycle

        init(sink: AgentApprovalSink, allowedKinds: Set<String>) {
            self.sink = sink
            self.allowedKinds = allowedKinds
        }

        // MARK: Internal

        typealias Input = ProposeActionArguments
        typealias Output = String

        static let name = "propose_action"
        static let description = """
        Propose an action for the user to approve BEFORE it happens (e.g. sending an email, \
        booking an event). You cannot perform these actions directly — this is the only way. \
        After calling propose_action, STOP and wait for the user's decision; never claim the \
        action was taken. Provide the action kind, a short title, optional detail to review, \
        and the action arguments as a JSON object string in payloadJSON.
        """

        static var inputSchema: JSONSchema {
            .object(
                properties: [
                    "kind": .string(description: "Action kind, e.g. send_email."),
                    "title": .string(description: "Short headline for the approval card."),
                    "detail": .string(description: "Longer detail to review (use \"\" if none)."),
                    "payloadJSON": .string(description: "Action arguments as a JSON object string."),
                ],
                required: ["kind", "title", "payloadJSON"]
            )
        }

        // MARK: Per-kind validators

        /// Returns `.valid` when the proposed payload is OK to
        /// record + show the user, or `.invalid(reason:)` with
        /// detailed feedback the model reads in its next step.
        /// Unknown kinds default to a non-empty-object check —
        /// custom kinds the host adds without registering a
        /// validator at least get protected from `{}` payloads.
        static func validate(kind: String, payload: JSONValue) -> ProposalValidationResult {
            switch kind {
            case "schedule_hydration_plan":
                return self.validateHydrationPlan(payload)
            case "schedule_notification":
                return self.validateScheduleNotification(payload)
            case "create_event":
                return self.validateCreateEvent(payload)
            case "create_reminder":
                return self.validateCreateReminder(payload)
            default:
                if case let .object(map) = payload, map.isEmpty {
                    return .invalid(
                        reason: "Payload was empty. \(kind) needs at least one field; check the action's documented argument shape."
                    )
                }
                return .valid
            }
        }

        func call(_ input: ProposeActionArguments, context _: ToolContext) async throws -> String {
            print("[AGENT] ProposeTool.call kind=\(input.kind) title=\(input.title) payloadJSON=\(input.payloadJSON)")
            if !self.allowedKinds.isEmpty, !self.allowedKinds.contains(input.kind) {
                let allowed = self.allowedKinds.sorted().joined(separator: ", ")
                print("[AGENT] ProposeTool.call REJECTED kind=\(input.kind) allowed=\(allowed)")
                return "Action kind \"\(input.kind)\" is not permitted for this agent. Allowed kinds: \(allowed)."
            }
            let payload = Self.decodePayload(input.payloadJSON)
            print("[AGENT] ProposeTool.call decoded payload=\(payload)")
            // In-loop validation — return any structural / semantic
            // problems as a TOOL OUTPUT string so the model sees
            // the reason in its next reasoning step and can
            // self-correct (re-propose with fixed values) without
            // ever bouncing to the user.
            let result = Self.validate(kind: input.kind, payload: payload)
            if case let .invalid(reason) = result {
                self.sink.recordRejection()
                let attemptCount = self.sink.rejectionCount
                print("[AGENT] ProposeTool.call INVALID kind=\(input.kind) attempt=\(attemptCount) reason=\(reason)")
                // Hard cap on retries. Small models tend to spam
                // the same malformed payload back rather than
                // genuinely self-correct from validator feedback,
                // which blows the context window. After
                // `maxRejections` attempts, send a one-way
                // "stop trying" message so the agent ends the
                // turn gracefully instead of looping until the
                // provider errors out with `exceededContextWindowSize`.
                guard attemptCount < Self.maxRejections else {
                    return """
                    STOP. You have called propose_action \(attemptCount) times with an invalid payload, \
                    each time receiving the same rejection reason.
                    Do NOT call propose_action again. The action cannot be completed in this run.
                    Reply to the user with a single short sentence explaining you couldn't carry out the action \
                    and then STOP. Do not retry, do not call any other tools.
                    """
                }
                return """
                Your propose_action call was REJECTED (attempt \(attemptCount) of \(Self
                    .maxRejections)) for the following reasons:

                \(reason)

                Fix the issues above and call propose_action AGAIN with a corrected payload. \
                Do NOT claim the action was taken — it wasn't, the proposal was not recorded.
                """
            }
            let proposal = AgentProposal(
                kind: input.kind,
                title: input.title,
                detail: input.detail,
                payload: payload
            )
            self.sink.record(proposal)
            return "Proposal \"\(input.title)\" recorded and is awaiting the user's approval. Stop now — do not take any further action or claim it was done."
        }

        // MARK: Private

        /// Hard cap on validator-rejected retries per turn.
        /// FoundationModels (and small models generally) tend to
        /// re-emit the same broken payload after seeing the
        /// validator's feedback rather than actually
        /// self-correcting — logs showed 10+ identical retries
        /// blowing the 4096-token context window. Three attempts
        /// is enough rope to recover from a one-off typo without
        /// being enough to overflow context.
        private static let maxRejections = 3

        private let sink: AgentApprovalSink
        private let allowedKinds: Set<String>

        /// Lenient JSON parse. Small models frequently emit one
        /// extra closing brace / bracket at the end of nested
        /// payloads (e.g. `{"reminders":[…]}}` instead of
        /// `{"reminders":[…]}`). Strict `JSONDecoder` rejects
        /// these, so the previous "parse-or-empty" implementation
        /// silently mapped a real-but-malformed payload to `{}`,
        /// and downstream the executor surfaced an "empty plan"
        /// error that misrepresented what actually happened.
        ///
        /// Strategy: try strict first; on failure, iteratively
        /// strip trailing `}` / `]` (up to 3 chars) and retry.
        /// Recovers the common LLM-emits-extra-close case without
        /// being so permissive it papers over real corruption.
        private static func decodePayload(_ raw: String) -> JSONValue {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .object([:])
            }
            if let value = Self.parseJSON(trimmed) {
                return value
            }
            var attempt = trimmed
            for _ in 0..<3 {
                guard let last = attempt.last, last == "}" || last == "]" else {
                    break
                }
                attempt.removeLast()
                if let value = Self.parseJSON(attempt) {
                    print(
                        "[AGENT] ProposeTool.decodePayload recovered by trimming \(trimmed.count - attempt.count) trailing close-bracket(s)"
                    )
                    return value
                }
            }
            print("[AGENT] ProposeTool.decodePayload FAILED to parse — falling back to empty. raw=\(raw)")
            return .object([:])
        }

        private static func parseJSON(_ raw: String) -> JSONValue? {
            guard let data = raw.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }

        private static func validateHydrationPlan(_ payload: JSONValue) -> ProposalValidationResult {
            guard case let .object(map) = payload else {
                return .invalid(reason: "Payload must be a JSON object containing a 'reminders' array.")
            }
            guard case let .array(reminders) = map["reminders"] ?? .null else {
                return .invalid(
                    reason: "Payload must contain a 'reminders' array. Shape: {\"reminders\":[{\"fireAt\":\"<ISO-8601>\",\"body\":\"<text>\"}, ...]}."
                )
            }
            if reminders.isEmpty {
                return .invalid(
                    reason: "The 'reminders' array was empty. Add at least one reminder before re-proposing."
                )
            }
            var problems: [String] = []
            for (index, reminder) in reminders.enumerated() {
                guard case let .object(map) = reminder else {
                    problems.append("reminders[\(index)] is not an object")
                    continue
                }
                let fireAtRaw = Self.firstString(in: map, keys: ["fireAt", "date", "time"])
                guard let iso = fireAtRaw else {
                    problems.append("reminders[\(index)] is missing 'fireAt' (ISO-8601 datetime)")
                    continue
                }
                guard let when = Self.parseISO8601(iso) else {
                    problems.append("reminders[\(index)].fireAt is not a valid ISO-8601 datetime (got '\(iso)')")
                    continue
                }
                if when <= Date() {
                    problems
                        .append(
                            "reminders[\(index)].fireAt is in the past ('\(iso)'). Use the Current date / instant from the system prompt and pick a future time."
                        )
                }
            }
            guard problems.isEmpty else {
                return .invalid(reason: problems.joined(separator: "\n"))
            }
            return .valid
        }

        private static func validateScheduleNotification(_ payload: JSONValue) -> ProposalValidationResult {
            guard case let .object(map) = payload else {
                return .invalid(reason: "Payload must be a JSON object with 'title', 'body', and 'fireAt'.")
            }
            var problems: [String] = []
            if Self.firstString(in: map, keys: ["title"]) == nil {
                problems.append("missing 'title' (string)")
            }
            let fireAtRaw = Self.firstString(in: map, keys: ["fireAt", "date", "when"])
            guard let iso = fireAtRaw else {
                problems.append("missing 'fireAt' (ISO-8601 datetime in the future)")
                return .invalid(reason: problems.joined(separator: "; "))
            }
            guard let when = Self.parseISO8601(iso) else {
                problems.append("'fireAt' is not a valid ISO-8601 datetime (got '\(iso)')")
                return .invalid(reason: problems.joined(separator: "; "))
            }
            if when <= Date() {
                problems
                    .append(
                        "'fireAt' is in the past ('\(iso)'). Use a future datetime based on the Current ISO instant in the system prompt."
                    )
            }
            return problems.isEmpty ? .valid : .invalid(reason: problems.joined(separator: "; "))
        }

        private static func validateCreateEvent(_ payload: JSONValue) -> ProposalValidationResult {
            guard case let .object(map) = payload else {
                return .invalid(reason: "Payload must be a JSON object with 'title', 'start', 'end'.")
            }
            var problems: [String] = []
            if Self.firstString(in: map, keys: ["title"]) == nil {
                problems.append("missing 'title' (string)")
            }
            let startRaw = Self.firstString(in: map, keys: ["start"])
            let endRaw = Self.firstString(in: map, keys: ["end"])
            guard let startISO = startRaw else {
                problems.append("missing 'start' (ISO-8601 datetime)")
                return .invalid(reason: problems.joined(separator: "; "))
            }
            guard let endISO = endRaw else {
                problems.append("missing 'end' (ISO-8601 datetime)")
                return .invalid(reason: problems.joined(separator: "; "))
            }
            guard let start = Self.parseISO8601(startISO) else {
                return .invalid(reason: "'start' is not a valid ISO-8601 datetime (got '\(startISO)').")
            }
            guard let end = Self.parseISO8601(endISO) else {
                return .invalid(reason: "'end' is not a valid ISO-8601 datetime (got '\(endISO)').")
            }
            if end <= start {
                problems.append("'end' (\(endISO)) is not after 'start' (\(startISO))")
            }
            return problems.isEmpty ? .valid : .invalid(reason: problems.joined(separator: "; "))
        }

        private static func validateCreateReminder(_ payload: JSONValue) -> ProposalValidationResult {
            guard case let .object(map) = payload else {
                return .invalid(reason: "Payload must be a JSON object with at least 'title'.")
            }
            if Self.firstString(in: map, keys: ["title"]) == nil {
                return .invalid(reason: "missing 'title' (string)")
            }
            // `due` is optional. If present, must parse — but
            // can be in the past (overdue reminder is valid).
            if let dueISO = Self.firstString(in: map, keys: ["due"]),
               Self.parseISO8601(dueISO) == nil {
                return .invalid(reason: "'due' is present but not a valid ISO-8601 datetime (got '\(dueISO)').")
            }
            return .valid
        }

        // MARK: Validator helpers

        private static func firstString(in map: [String: JSONValue], keys: [String]) -> String? {
            for key in keys {
                if case let .string(value) = map[key] ?? .null, !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        /// Permissive ISO-8601 parser — mirrors the executor's
        /// strategy. Try with fractional seconds first, then
        /// without; both shapes show up in model output.
        private static func parseISO8601(_ raw: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }
    }

    // MARK: - ProposalValidationResult

    /// Outcome of `ProposeTool`'s in-loop payload validation. The
    /// `.invalid` case carries a model-readable reason string —
    /// the tool returns it as its output so the agent sees the
    /// feedback in its next reasoning step and can self-correct.
    enum ProposalValidationResult {
        case valid
        case invalid(reason: String)
    }

    // MARK: - ProposeToolKitBuilder

    /// Builds the `FoundationModelsToolKit` for `propose_action` bound to
    /// a run's approval sink. Called by `AgentCompiler` only when the
    /// agent's `approvalPolicy` is `.proposeThenConfirm`.
    @available(iOS 26.0, macOS 26.0, *)
    enum ProposeToolKitBuilder {
        static func makeKit(
            sink: AgentApprovalSink,
            allowedKinds: Set<String>
        ) -> FoundationModelsToolKit {
            registerFoundationModelsTool(ProposeTool(sink: sink, allowedKinds: allowedKinds))
        }
    }

#endif
