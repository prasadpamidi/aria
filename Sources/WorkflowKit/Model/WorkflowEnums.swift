import Foundation

// MARK: - CapabilityID

/// Stable identifiers for every capability the broker can route a
/// call to. Native capabilities (Apple-framework backed) live in
/// `WorkflowKit/Capabilities/`. JS plugins declare which ids they
/// need in their manifest; user grants are scoped per id.
///
/// The set is closed by design — adding a new capability is a code
/// change, not a user-installable surface. That keeps the consent
/// model explicit: the install sheet always lists from a known
/// vocabulary, never an opaque plugin-declared string.
public enum CapabilityID: String, Codable, CaseIterable, Sendable {
    /// Keychain-backed key vault. Read/write/list, optionally
    /// biometric-gated per key. Lands in slice 4.
    case secrets
    /// HealthKit reads — steps, sleep, workouts, water. Lands in
    /// slice 7.
    case health
    /// EventKit reads — events + reminders. Lands in slice 6.
    case calendar
    /// CoreLocation one-shot + geocoding. Lands in slice 8.
    case location
    /// User-picked file reads (text + PDF). Lands in slice 9.
    case files
    /// HTTP capability — already exists in AriaTools as
    /// `HTTPTool`. Listed here so the broker can mediate manifest
    /// declarations alongside the native caps.
    case http
}

// MARK: - Trigger

/// Surfaces from which a workflow can be invoked. A workflow
/// declares its supported triggers up front; the trigger
/// dispatcher (`Apps/AvyraApp/Avyra/Intents/`) uses this set to
/// decide whether to register an AppIntent, listen for a URL
/// scheme, etc.
public enum Trigger: String, Codable, Sendable {
    /// Run from inside Avyra (e.g. tapping the workflow's row in
    /// the library). Always implicitly available — no system
    /// integration needed.
    case manual
    /// Exposed as an AppIntent so it shows up in Shortcuts.app,
    /// Siri, Spotlight, Watch, etc.
    case shortcuts
    /// Reachable via the `avyra://run?workflow=<id>&input=<…>`
    /// custom URL scheme.
    case urlScheme
}

// MARK: - ModelFamilyHint

/// Soft preference for which provider family a workflow's LLM
/// steps should run against. The runtime treats this as a hint —
/// if the preferred family is unavailable on-device, the workflow
/// falls back to whatever provider the agent is configured with.
public enum ModelFamilyHint: String, Codable, Sendable {
    case foundationModels
    case llama
    case qwen
    case gemma
    /// "Whatever's available" — picks the active default.
    case any
}

// MARK: - InputField

/// Typed parameter declaration for a workflow. Used to drive the
/// AppIntent parameter surface (Siri / Shortcuts) and the
/// in-editor "run with…" sheet. P0 supports only the four
/// scalar kinds enumerated here; richer typed entities arrive in
/// P1.
public struct InputField: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(id: String, label: String, kind: Kind, optional: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.optional = optional
    }

    // MARK: Public

    public enum Kind: String, Codable, Sendable {
        case text
        case date
        case number
        case bool
    }

    public let id: String
    public let label: String
    public let kind: Kind
    public let optional: Bool
}

// MARK: - InputSchema

public struct InputSchema: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(fields: [InputField] = []) {
        self.fields = fields
    }

    // MARK: Public

    public let fields: [InputField]
}

// MARK: - OutputField

/// Declared output binding shape. The final `output` node in a
/// workflow populates these field ids; the runner returns them
/// to the caller (AppIntent result, URL-scheme x-callback payload,
/// in-app library "Run" button result panel).
public struct OutputField: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    // MARK: Public

    public let id: String
    public let label: String
}

// MARK: - OutputSchema

public struct OutputSchema: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(fields: [OutputField] = []) {
        self.fields = fields
    }

    // MARK: Public

    public let fields: [OutputField]
}
