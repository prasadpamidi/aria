import Aria

/// AriaToolsJS — JavaScript-backed user tool plugin runtime.
///
/// Loads plugin bundles (default extension `.aria-tool`; one JSON
/// file with embedded JS per `JSToolBundle`), instantiates per-tool
/// sandboxed `JSContext`s, wires a curated `<global>.*` bridge object
/// (default global name `Aria`; both configurable per host) based
/// on each tool's declared capabilities, and vends them to the
/// agent as `AnyTool`s. The bridge surface is intentionally small — HTTP,
/// JSON, clipboard, share, notify, storage. Sensitive system
/// frameworks (HealthKit, Calendar, etc.) are out of scope for v1.
///
/// Apple-only — the implementation requires `JavaScriptCore`. The
/// target's sources are guarded with `#if canImport(JavaScriptCore)`
/// so it compiles empty on Linux without breaking the package.
public enum AriaToolsJS {
    /// The current version. Matches `AriaInfo.version` in lockstep.
    public static let version = AriaInfo.version
}
