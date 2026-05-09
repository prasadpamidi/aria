import Aria

/// AriaTools — Cross-platform tool implementations.
///
/// Tools that do not require Apple frameworks live here and can be used on
/// any platform Aria supports. Tools that require Apple frameworks (Calendar,
/// HealthKit, EventKit, Contacts) live in `AriaApple` under a `Tools` subfolder.
///
/// Examples of tools intended for this module:
/// - `HTTPTool` (uses an injected `HTTPClient`)
/// - `CalculatorTool`
/// - `JSONPathTool`
/// - `RegexExtractTool`
public enum AriaTools {
    /// The current version. Matches `Aria.version` in lockstep.
    public static let version = Aria.version
}
