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
    /// System clipboard (`UIPasteboard`) read + write. Powers
    /// the "paste your X, get Y" class of workflows (tone
    /// adjuster, email drafter, receipt to pantry, etc.). iOS
    /// 14+ shows a clipboard-access toast on every read; no
    /// extra Info.plist key required.
    case clipboard
    /// System share sheet (`UIActivityViewController`). Lets a
    /// workflow hand its final output to whatever destination
    /// the user picks (Mail, Messages, Notes, …). Requires an
    /// interactive context — calls from background Shortcuts /
    /// Siri / AppIntent contexts surface `.unavailable`.
    case share
    /// Local notification scheduling via
    /// `UNUserNotificationCenter`. Powers reminders like the
    /// Hydration Coach, Bill Tracker, and Sleep Wind-Down
    /// workflows. Works in background contexts (Shortcuts /
    /// Siri / AppIntent) since scheduling doesn't need a
    /// foreground window.
    case notifications
    /// iOS Focus state read + suggest. Read-only —
    /// Apple intentionally doesn't expose programmatic
    /// *write* to Focus mode; we surface a "suggest switch"
    /// affordance that drops the user into the system picker.
    case focus
    /// Run a named iOS Shortcut from a workflow step via the
    /// Shortcuts `x-callback-url` scheme. Lets workflows
    /// chain into user-authored Shortcuts as side effects.
    case shortcuts
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

// MARK: - TimeOfDay

/// Coarse-grained "when is this workflow most useful" tag used
/// by Home's "Suggested for now" rail. Each workflow can carry
/// any subset; the suggester picks workflows whose tags match
/// the current local-time bucket. Workflows with no tags fall
/// back to `.anytime` semantics — eligible at any bucket but
/// outranked by an explicit match.
///
/// The buckets intentionally mirror the greeting-hero
/// thresholds in HomeScreen (morning = 5-12, afternoon = 12-17,
/// evening = 17-22, otherwise night) so a 7 a.m. user sees the
/// "Good morning" greeting AND the morning-tagged workflows in
/// the same render.
public enum TimeOfDay: String, Codable, CaseIterable, Sendable {
    case morning
    case afternoon
    case evening
    case night
    case anytime

    // MARK: Public

    /// Map an absolute `Date` to the bucket Home should query
    /// against. Single source of truth so the greeting and the
    /// suggester never drift.
    public static func bucket(for date: Date, calendar: Calendar = .current) -> TimeOfDay {
        let hour = calendar.component(.hour, from: date)
        return switch hour {
        case 5..<12: .morning
        case 12..<17: .afternoon
        case 17..<22: .evening
        default: .night
        }
    }
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

// MARK: - OutputRenderMode

/// How an output field should be presented in the workflow's
/// run-result panel. Stored per-field on `OutputStep.renderModes`
/// so the same workflow can have one field surface as readable
/// markdown, another as code, and another as spoken voice.
///
/// `.plain` is the default and what every existing workflow
/// decodes as when no explicit hint is stored. Renderers fall
/// back to plain when they hit a value they can't natively
/// represent (e.g. requesting markdown on a JSON array).
public enum OutputRenderMode: Codable, Sendable, Equatable, Hashable {
    /// Default — monospaced text, copy-selectable. What every
    /// pre-render-mode workflow gets at decode time.
    case plain
    /// Rich markdown. Uses the same `Markdown` rendering the
    /// chat surface uses (headings, lists, fenced code blocks,
    /// links). Best for prose-heavy outputs (summaries,
    /// emails, briefs).
    case markdown
    /// Code listing in a monospaced block. The optional
    /// `language` hint drives syntax-highlighting today's
    /// renderer doesn't apply (room for follow-up), but the
    /// value is captured so a later upgrade can wire it
    /// through without a schema migration. Examples: `"swift"`,
    /// `"python"`, `"json"`.
    case code(language: String?)
    /// Read aloud via the system TTS provider. The renderer
    /// shows a play/stop control instead of the text body; the
    /// text is still copy-selectable behind a disclosure for
    /// accessibility.
    case voice

    // MARK: Public

    /// Every choice the picker should offer, in display order.
    /// `.code` defaults its language to `nil` (auto / no hint).
    public static let allPickerCases: [OutputRenderMode] = [
        .plain,
        .markdown,
        .code(language: nil),
        .voice,
    ]

    /// Stable string id used by the editor's picker. Decoupled
    /// from `rawValue` because the enum has an associated value
    /// (so it can't be `RawRepresentable`); a separate
    /// switchable id keeps the picker bindings simple.
    public var pickerID: String {
        switch self {
        case .plain: "plain"
        case .markdown: "markdown"
        case .code: "code"
        case .voice: "voice"
        }
    }

    /// User-facing label for the picker. Localisable later if
    /// the catalogue ever ships in non-English locales.
    public var displayName: String {
        switch self {
        case .plain: "Plain text"
        case .markdown: "Markdown"
        case .code: "Code"
        case .voice: "Voice"
        }
    }

    public var systemImage: String {
        switch self {
        case .plain: "doc.plaintext"
        case .markdown: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .voice: "speaker.wave.2.fill"
        }
    }
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
