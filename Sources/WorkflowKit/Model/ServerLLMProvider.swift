import Foundation

// MARK: - ServerLLMProvider

/// One configured server-side LLM endpoint. Carries the kind
/// (OpenAI / Anthropic / Gemini), a user-friendly name, the
/// model id to request, a credential reference for the API
/// token, and optional sampling overrides.
///
/// Persisted to `UserDefaults` via the app-side
/// `ServerProviderStore` — non-sensitive (the token lives in
/// Keychain under the referenced credential). Multiple
/// instances of the same kind are allowed so a user can have
/// "OpenAI personal" + "OpenAI work" pointing at different
/// tokens.
///
/// Lives in `WorkflowKit` (not the app target) so the engine's
/// resolver bridges, the chat-side `ServerChatLLMProvider`
/// adapter, and the workflow editor all share one type
/// definition. Being in `WorkflowKit` also means the standard
/// non-isolated default applies, so no `nonisolated`
/// annotations are needed to make the value type's properties
/// readable from off-main contexts.
public struct ServerLLMProvider: Codable, Identifiable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        credentialID: UUID?,
        baseURL: String? = nil,
        model: String,
        temperature: Double = 0.7,
        maxTokens: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.credentialID = credentialID
        self.baseURL = baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.createdAt = createdAt
    }

    // MARK: Public

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case openai
        case anthropic
        case gemini

        // MARK: Public

        public var displayName: String {
            switch self {
            case .openai: "OpenAI"
            case .anthropic: "Anthropic"
            case .gemini: "Google Gemini"
            }
        }

        /// SF Symbol used in lists / pickers when a brand
        /// asset isn't available.
        public var symbol: String {
            switch self {
            case .openai: "cloud.bolt"
            case .anthropic: "cloud.fog"
            case .gemini: "cloud.sun"
            }
        }

        /// `Assets.xcassets` image name for the vendor's brand
        /// mark. Used by `ModelBrandIcon` in the model picker
        /// and chat-toolbar pill so the row shows the actual
        /// OpenAI / Anthropic / Gemini glyph instead of a
        /// generic cloud symbol. Returns nil only if the asset
        /// is missing from the catalog (defensive — all three
        /// are bundled).
        public var brandAsset: String? {
            switch self {
            case .openai: "openai-color"
            case .anthropic: "anthropic-color"
            case .gemini: "gemini-color"
            }
        }

        /// Default base URL for first-party endpoints. Users
        /// can override (Azure-hosted OpenAI, self-hosted
        /// Anthropic gateway, etc.) — stored separately on the
        /// provider so the default doesn't pin the choice.
        public var defaultBaseURL: String {
            switch self {
            case .openai: "https://api.openai.com/v1"
            case .anthropic: "https://api.anthropic.com/v1"
            case .gemini: "https://generativelanguage.googleapis.com/v1beta"
            }
        }

        /// Reasonable default model when the user adds a
        /// provider — they can change it in the editor. Chosen
        /// to be the cheapest "good enough" model from each
        /// vendor at provider-creation time.
        public var defaultModel: String {
            switch self {
            case .openai: "gpt-4o-mini"
            case .anthropic: "claude-3-5-haiku-latest"
            case .gemini: "gemini-2.5-flash"
            }
        }

        /// Short cost / quality note rendered next to the
        /// kind in the editor so the user makes an informed
        /// pick without leaving the app.
        public var pricingHint: String {
            switch self {
            case .openai:
                "Paid per-token. GPT-4o family. Requires network. Doesn't run in background / Shortcuts."
            case .anthropic:
                "Paid per-token. Claude family. Requires network. Doesn't run in background / Shortcuts."
            case .gemini:
                "Generous free tier. Gemini 2.5 family. Requires network. Doesn't run in background / Shortcuts."
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    public var name: String
    /// Reference into `CredentialStore`. `nil` while the editor
    /// is being filled in; the engine refuses to run a provider
    /// with a missing credential.
    public var credentialID: UUID?
    /// Custom endpoint. When `nil`, the engine uses
    /// `kind.defaultBaseURL`.
    public var baseURL: String?
    public var model: String
    public var temperature: Double
    public var maxTokens: Int?
    public let createdAt: Date

    /// Resolved endpoint — explicit override falls back to
    /// the kind's default. Trimmed of trailing slashes so
    /// path joins are predictable.
    public var resolvedBaseURL: String {
        let raw = self.baseURL?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? self.baseURL!
            : self.kind.defaultBaseURL
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
