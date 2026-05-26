import WorkflowKit

// MARK: - CapabilityMethod

/// Static, model-facing metadata for one capability method. Drives
/// both the tool description the agent reads (so it knows which JSON
/// args to send) and the HITL gating decision (`isSideEffecting`
/// methods are kept out of an agent's surface under
/// `.proposeThenConfirm`).
public struct CapabilityMethod: Sendable, Equatable {
    // MARK: Lifecycle

    public init(name: String, summary: String, argHint: String, isSideEffecting: Bool) {
        self.name = name
        self.summary = summary
        self.argHint = argHint
        self.isSideEffecting = isSideEffecting
    }

    // MARK: Public

    /// Wire method name passed to `CapabilityBroker.call`.
    public let name: String
    /// One-line, model-facing description of what the method does.
    public let summary: String
    /// Human/model-readable JSON argument contract, e.g.
    /// `{"days": integer (optional, default 7)}` or `"No arguments."`.
    public let argHint: String
    /// `true` for methods that mutate state or fire side effects
    /// (create event, schedule notification, run shortcut, …). The
    /// approval layer keeps these out of an agent's direct tool
    /// surface; the host executes them after the user approves a
    /// proposal.
    public let isSideEffecting: Bool
}

// MARK: - CapabilityCatalog

/// Curated table of the native capability methods an agent can be
/// granted as tools. The `CapabilityBroker` holds the live impls but
/// doesn't expose per-method metadata, so this catalog is the source
/// of truth for (a) expanding "all methods" when an agent has no
/// allowlist, (b) the builder UI's method picker, and (c) the
/// model-facing descriptions.
///
/// Intentionally narrower than the full `CapabilityID` set: `secrets`
/// (biometric), `files` and `share` (need an interactive / picked
/// context) are omitted from the autonomous agent surface for v1.
public enum CapabilityCatalog {
    // MARK: Public

    /// Capabilities offered to agents, in display order.
    public static let agentCapabilities: [CapabilityID] = [
        .calendar,
        .health,
        .http,
        .location,
        .notifications,
        .clipboard,
        .focus,
        .shortcuts,
    ]

    /// Methods for `capability`, or `[]` when the capability isn't
    /// offered to agents.
    public static func methods(for capability: CapabilityID) -> [CapabilityMethod] {
        self.table[capability] ?? []
    }

    public static func method(_ name: String, in capability: CapabilityID) -> CapabilityMethod? {
        self.methods(for: capability).first { $0.name == name }
    }

    // MARK: Private

    private static let table: [CapabilityID: [CapabilityMethod]] = [
        .calendar: [
            CapabilityMethod(
                name: "eventsToday",
                summary: "List today's calendar events.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "eventsBetween",
                summary: "List calendar events in a date range.",
                argHint: "{\"start\": ISO-8601 datetime, \"end\": ISO-8601 datetime}",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "upcomingReminders",
                summary: "List upcoming reminders.",
                argHint: "{\"limit\": integer (optional, default 5)}",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "createEvent",
                summary: "Create a calendar event.",
                argHint: "{\"title\": string, \"start\": ISO-8601 datetime, \"end\": ISO-8601 datetime, \"notes\": string (optional)}",
                isSideEffecting: true
            ),
            CapabilityMethod(
                name: "createReminder",
                summary: "Create a reminder.",
                argHint: "{\"title\": string, \"due\": ISO-8601 datetime (optional)}",
                isSideEffecting: true
            ),
        ],
        .health: [
            CapabilityMethod(
                name: "recentSteps",
                summary: "Step counts over recent days.",
                argHint: "{\"days\": integer (optional, default 7)}",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "lastSleep",
                summary: "Most recent sleep summary.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "lastWorkout",
                summary: "Most recent workout.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "waterToday",
                summary: "Today's water intake.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
        ],
        .http: [
            CapabilityMethod(
                name: "fetch",
                summary: "Fetch a URL and return the response body as text.",
                argHint: "{\"url\": string}",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "fetchJSON",
                summary: "Fetch a URL and return parsed JSON.",
                argHint: "{\"url\": string}",
                isSideEffecting: false
            ),
        ],
        .location: [
            CapabilityMethod(
                name: "current",
                summary: "One-shot current device location.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "geocode",
                summary: "Geocode an address to coordinates.",
                argHint: "{\"address\": string}",
                isSideEffecting: false
            ),
        ],
        .notifications: [
            CapabilityMethod(
                name: "pending",
                summary: "List pending local notifications.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "schedule",
                summary: "Schedule a local notification at a specific date.",
                // Broker requires `fireAt` (ISO-8601). Previous
                // hint said `date` which was stale — the model
                // would emit `date` and the broker rejected the
                // call with `expected: fireAt`. Aligned now.
                argHint: "{\"title\": string, \"body\": string, \"fireAt\": ISO-8601 datetime in the future}",
                isSideEffecting: true
            ),
            CapabilityMethod(
                name: "scheduleIn",
                summary: "Schedule a local notification after a delay.",
                // Real broker arg is `secondsFromNow` (positive int),
                // not `seconds`. Aligned with `NotificationsCapability`.
                argHint: "{\"title\": string, \"body\": string, \"secondsFromNow\": positive integer}",
                isSideEffecting: true
            ),
            CapabilityMethod(
                name: "cancel",
                summary: "Cancel a scheduled notification by id.",
                argHint: "{\"identifier\": string}",
                isSideEffecting: true
            ),
        ],
        .clipboard: [
            CapabilityMethod(
                name: "read",
                summary: "Read text from the clipboard.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
            CapabilityMethod(
                name: "write",
                summary: "Write text to the clipboard.",
                argHint: "{\"text\": string}",
                isSideEffecting: true
            ),
        ],
        .focus: [
            CapabilityMethod(
                name: "current",
                summary: "Read the current Focus status.",
                argHint: "No arguments.",
                isSideEffecting: false
            ),
        ],
        .shortcuts: [
            CapabilityMethod(
                name: "run",
                summary: "Run a named iOS Shortcut.",
                argHint: "{\"name\": string, \"input\": string (optional)}",
                isSideEffecting: true
            ),
        ],
    ]
}
