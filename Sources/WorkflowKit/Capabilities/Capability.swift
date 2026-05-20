import Aria
import Foundation

// MARK: - Capability

/// Protocol every capability implementation conforms to. A
/// capability is the runtime contract behind a `CapabilityID` —
/// `secrets`, `health`, `calendar`, and friends each ship one
/// concrete `Capability` and register themselves with the
/// `CapabilityBroker` at app boot.
///
/// Methods are dispatched by name (string). Capability impls
/// enumerate which methods they accept; unknown methods throw
/// `CapabilityError.unknownMethod` rather than silently no-oping.
/// The string-keyed dispatch is what lets the JS bridge call
/// natives via `aria.health.recentSteps({ days: 7 })` without a
/// per-method Swift bridge function — one bridge function
/// forwards everything.
public protocol Capability: Sendable {
    /// Capability id this impl handles. The broker uses this to
    /// route calls.
    var id: CapabilityID { get }

    /// Set of methods this capability accepts. Used for the
    /// "did you typo?" path in `CapabilityBroker.call(...)` and
    /// for `ConsentSheetModel` to surface a per-method audit if
    /// a future manifest ever wants method-level grants.
    var supportedMethods: Set<String> { get }

    /// Execute one method call. Arguments are pre-interpolated by
    /// the workflow runner (or built directly by JS callers).
    /// Returns a `JSONValue` for uniform downstream binding into
    /// workflow state.
    func call(
        method: String,
        arguments: [String: JSONValue],
        context: CapabilityCallContext
    ) async throws -> JSONValue
}

// MARK: - CapabilityCallContext

/// Per-call context the broker hands to a capability. Carries
/// enough metadata for the capability to enforce scope (which
/// plugin / workflow asked) and to emit useful trace spans /
/// metrics labels without each impl re-deriving them.
public struct CapabilityCallContext: Sendable {
    // MARK: Lifecycle

    public init(
        callerPluginID: String?,
        callerWorkflowID: UUID?,
        attended: Bool
    ) {
        self.callerPluginID = callerPluginID
        self.callerWorkflowID = callerWorkflowID
        self.attended = attended
    }

    // MARK: Public

    /// Bundle id of the plugin that initiated the call, when the
    /// caller is a JS plugin. `nil` for first-party native
    /// calls (e.g. a built-in Daily Brief workflow firing a
    /// capability directly).
    public let callerPluginID: String?

    /// Workflow that invoked this call. `nil` for ad-hoc invocation
    /// (developer-mode "run capability directly" surfaces).
    public let callerWorkflowID: UUID?

    /// Whether the call is happening with a user actively present
    /// in the app. `false` for Siri / widget / scheduled
    /// invocations — biometric prompts can't render in those
    /// modes and capabilities should fail gracefully (e.g.
    /// `SecretsCapability` returns nil for biometric-gated keys
    /// instead of throwing).
    public let attended: Bool
}

// MARK: - CapabilityError

/// Closed set of failure modes a capability call can produce.
/// The broker surfaces these unchanged so callers can switch on
/// the concrete case (e.g. show a "grant access" sheet when
/// `.notGranted` fires, retry on `.unavailable`).
public enum CapabilityError: Error, Sendable, Equatable {
    /// User hasn't granted this capability to this caller. The
    /// associated `requiredScope` tells the consent layer what to
    /// ask for next.
    case notGranted(CapabilityScope)
    /// The capability is granted but the requested method doesn't
    /// exist. Useful for spotting JS-bridge typos in development.
    case unknownMethod(capability: CapabilityID, method: String)
    /// Argument shape doesn't match what the method expects.
    /// `expected` and `actual` are human-readable diagnostics; not
    /// machine-parseable.
    case invalidArguments(method: String, expected: String, actual: String)
    /// The underlying iOS framework is not available on this
    /// device or could not be reached (e.g. HealthKit on iPad
    /// running iOS 17 without the framework, or a transient
    /// EventKit error). Caller can retry or fall back.
    case unavailable(reason: String)
    /// A biometric prompt was required but the call was
    /// `unattended`. Native capabilities convert this to a
    /// graceful nil-return rather than throwing in production;
    /// the throw exists for tests + explicit dev probes.
    case biometricRequiredButUnattended
    /// Catch-all for unexpected runtime errors. Carries the
    /// underlying error's description for log surfacing.
    case underlying(String)
}
