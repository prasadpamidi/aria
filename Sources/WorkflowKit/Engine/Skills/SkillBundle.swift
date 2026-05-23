import Foundation

// MARK: - SkillBundleReader

/// Reads a skill bundle directory from disk. The directory
/// contains:
///
///   * `SKILL.md` — the canonical Anthropic-style file: YAML
///     frontmatter (`---` … `---`) followed by markdown body.
///   * `manifest.json` (optional) — host-side metadata
///     (`id`, `origin`, `createdAt`, `enabled`, etc) the
///     SKILL.md frontmatter doesn't natively carry. Generated
///     on first install; rewritten on every metadata edit.
///   * `helpers/` and `references/` (optional) — auxiliary
///     files the body may reference. P0 treats these as
///     read-only context; no execution surface yet (plan §7
///     open question 2).
///
/// The reader is `Sendable` (stateless) and safe to call from
/// any actor. All I/O is synchronous because callers are
/// typically already off the main actor (`@MainActor` store
/// dispatches into a `Task.detached` for bulk loads).
public enum SkillBundleReader {
    // MARK: Public

    /// Locate and parse a bundle at `directoryURL`. Returns the
    /// raw `SkillDocument` (frontmatter + body) plus the
    /// sidecar manifest if one exists.
    public static func read(directoryURL: URL) throws -> (document: SkillDocument, manifest: SkillBundleManifest?) {
        let skillURL = directoryURL.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillURL.path) else {
            throw SkillError.bundleNotFound(directoryURL)
        }
        let raw: String
        do {
            raw = try String(contentsOf: skillURL, encoding: .utf8)
        } catch {
            throw SkillError.unreadableSkillFile(skillURL)
        }
        let document = try SkillFrontmatterParser.parse(raw)
        let manifest = try Self.readManifest(at: directoryURL.appendingPathComponent("manifest.json"))
        return (document, manifest)
    }

    /// Discover every skill bundle under `rootURL`. Each
    /// immediate subdirectory containing a `SKILL.md` is a
    /// candidate. Subdirectories without that file are
    /// silently ignored — same lenient pattern the JS plugin
    /// installer uses, which avoids strict error surfaces on
    /// partially-installed bundles.
    public static func enumerateBundleDirectories(under rootURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { url in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            return fileManager.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
        }
    }

    /// List every helper / reference file under the bundle
    /// directory (anything other than `SKILL.md` and
    /// `manifest.json`). Returned as URLs for callers that want
    /// to expose them as attachments or copy them into a
    /// re-export zip.
    public static func helperFileURLs(in directoryURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .compactMap { $0 as? URL }
            .filter {
                let last = $0.lastPathComponent
                return last != "SKILL.md" && last != "manifest.json"
            }
    }

    // MARK: Private

    private static func readManifest(at url: URL) throws -> SkillBundleManifest? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SkillBundleManifest.self, from: data)
    }
}

// MARK: - SkillBundleWriter

/// Writes a skill back to disk. Used by the authoring editor
/// and the import / download paths. Skills always live under a
/// per-skill subdirectory keyed by UUID so renames in the
/// frontmatter don't change the on-disk location.
public enum SkillBundleWriter {
    /// Write `SKILL.md` + `manifest.json` into `directoryURL`,
    /// creating intermediate directories as needed. Overwrites
    /// any existing files. Helper / reference files are
    /// untouched — callers that import a zip handle those
    /// during extraction.
    public static func write(
        document: SkillDocument,
        manifest: SkillBundleManifest,
        to directoryURL: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let skillURL = directoryURL.appendingPathComponent("SKILL.md")
        let serialised = SkillFrontmatterSerialiser.serialise(document: document, manifestID: manifest.id)
        try serialised.write(to: skillURL, atomically: true, encoding: .utf8)
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    /// Delete the bundle directory. Idempotent.
    public static func delete(directoryURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return
        }
        try fileManager.removeItem(at: directoryURL)
    }
}

// MARK: - SkillFrontmatterParser

/// Hand-rolled YAML frontmatter reader. Scope is intentionally
/// narrow — we don't ship a full YAML implementation, just
/// what `SKILL.md` files need:
///
///   * `key: value` scalar lines (quoted or bare).
///   * Inline lists: `key: [a, b, c]`.
///   * Block lists:
///     ```
///     key:
///       - a
///       - b
///     ```
///   * `#` line comments outside quotes.
///   * Booleans (`true` / `false`) and integers parse as
///     scalars; the caller coerces.
///
/// Anything else throws `SkillError.malformedFrontmatter`.
/// That keeps the surface tiny + auditable and avoids pulling
/// in `Yams`.
public enum SkillFrontmatterParser {
    // MARK: Public

    /// Parse the raw `SKILL.md` file text into a `SkillDocument`.
    /// The leading `---` ... `---` block is the frontmatter; the
    /// rest is the body.
    public static func parse(_ raw: String) throws -> SkillDocument {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            throw SkillError.missingFrontmatter
        }
        // Split on the closing fence. The opener consumes the
        // leading "---" + newline; the closer is a line that's
        // exactly "---" (after trim).
        let afterOpener = String(trimmed.dropFirst(3))
        guard let endRange = afterOpener.range(of: "\n---", options: []) else {
            throw SkillError.missingFrontmatter
        }
        let frontBlock = String(afterOpener[..<endRange.lowerBound])
        let afterCloser = afterOpener[endRange.upperBound...]
        // The closer line might be followed by `\n` + body. Drop
        // the trailing newline so the body doesn't start with
        // one.
        let body = afterCloser
            .drop(while: { $0 == "\n" || $0 == "\r" })
        let raw = self.parseDictionary(frontBlock)
        let frontmatter = try self.buildFrontmatter(from: raw)
        return SkillDocument(frontmatter: frontmatter, body: String(body))
    }

    // MARK: Fileprivate

    fileprivate enum RawValue {
        case scalar(String)
        case list([String])
    }

    // MARK: Private

    /// Bundle of the mutable bookkeeping `parseDictionary` carries
    /// across lines — pulled out so the main loop reads as a
    /// sequence of state transitions instead of a tangle of local
    /// vars + flushes.
    private struct ParseState {
        var result: [String: RawValue] = [:]
        var pendingKey: String?
        var pendingList: [String] = []

        mutating func flushPendingList() {
            guard let key = self.pendingKey else {
                return
            }
            self.result[key] = .list(self.pendingList)
            self.pendingKey = nil
            self.pendingList = []
        }
    }

    // MARK: - Raw-value helpers

    private static func optionalScalar(from raw: [String: RawValue], key: String) -> String? {
        if case let .scalar(value) = raw[key] {
            return value
        }
        return nil
    }

    private static func optionalUUID(from raw: [String: RawValue], key: String) -> UUID? {
        guard case let .scalar(value) = raw[key] else {
            return nil
        }
        return UUID(uuidString: value)
    }

    private static func stringList(from raw: [String: RawValue], key: String) -> [String] {
        if case let .list(items) = raw[key] {
            return items
        }
        if case let .scalar(value) = raw[key] {
            return [value].filter { !$0.isEmpty }
        }
        return []
    }

    private static func scalarBool(from raw: [String: RawValue], key: String) -> Bool {
        guard case let .scalar(value) = raw[key] else {
            return false
        }
        return value.lowercased() == "true"
    }

    private static func parseDictionary(_ block: String) -> [String: RawValue] {
        var state = ParseState()
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        for rawLine in lines {
            let stripped = self.stripComment(String(rawLine))
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            if state.pendingKey != nil, let item = self.matchBlockListItem(stripped) {
                state.pendingList.append(item)
                continue
            }
            state.flushPendingList()
            self.absorbKeyValueLine(stripped, into: &state)
        }
        state.flushPendingList()
        return state.result
    }

    /// Workhorse split out of `parseDictionary` so each remains
    /// under the strict 40-line function-body cap. Mutates the
    /// parser state in place based on whether the line declares a
    /// new key, an inline list, or starts a block list.
    private static func absorbKeyValueLine(_ stripped: String, into state: inout ParseState) {
        guard let separatorRange = stripped.range(of: ":") else {
            return
        }
        let key = stripped[..<separatorRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let valuePart = stripped[separatorRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        if valuePart.isEmpty {
            state.pendingKey = key
            state.pendingList = []
            return
        }
        if valuePart.hasPrefix("[") {
            state.result[key] = .list(self.parseInlineList(valuePart))
        } else {
            state.result[key] = .scalar(self.unquote(valuePart))
        }
    }

    private static func matchBlockListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else {
            return nil
        }
        let after = String(trimmed.dropFirst(2))
        return self.unquote(after)
    }

    private static func parseInlineList(_ value: String) -> [String] {
        var trimmed = value
        if trimmed.hasPrefix("[") {
            trimmed.removeFirst()
        }
        if trimmed.hasSuffix("]") {
            trimmed.removeLast()
        }
        return trimmed
            .split(separator: ",")
            .map { self.unquote(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func stripComment(_ line: String) -> String {
        // Strip trailing `# comment` only when outside quotes.
        var inSingle = false
        var inDouble = false
        var end = line.endIndex
        var idx = line.startIndex
        while idx < line.endIndex {
            let char = line[idx]
            if char == "\"", !inSingle {
                inDouble.toggle()
            } else if char == "'", !inDouble {
                inSingle.toggle()
            } else if char == "#", !inSingle, !inDouble {
                end = idx
                break
            }
            idx = line.index(after: idx)
        }
        return String(line[..<end])
    }

    private static func unquote(_ value: String) -> String {
        var trimmed = value
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        } else if trimmed.hasPrefix("'") && trimmed.hasSuffix("'"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func buildFrontmatter(from raw: [String: RawValue]) throws -> SkillFrontmatter {
        guard case let .scalar(name) = raw["name"] else {
            throw SkillError.missingRequiredField("name")
        }
        guard case let .scalar(description) = raw["description"] else {
            throw SkillError.missingRequiredField("description")
        }
        return SkillFrontmatter(
            id: self.optionalUUID(from: raw, key: "id"),
            name: name,
            description: description,
            modelHint: self.optionalScalar(from: raw, key: "model"),
            allowedTools: self.stringList(from: raw, key: "allowed-tools"),
            alwaysInline: self.scalarBool(from: raw, key: "always-inline"),
            version: self.optionalScalar(from: raw, key: "version")
        )
    }
}

// MARK: - SkillFrontmatterSerialiser

/// Serialise a `SkillDocument` back to disk text. Pair with the
/// parser — what we read, we should be able to write. Stable
/// key order (id, name, description, model, allowed-tools,
/// always-inline, version) so version-control diffs stay
/// readable.
public enum SkillFrontmatterSerialiser {
    // MARK: Public

    public static func serialise(document: SkillDocument, manifestID: UUID) -> String {
        var lines = ["---"]
        lines.append("id: \(manifestID.uuidString)")
        lines.append("name: \(self.quoteIfNeeded(document.frontmatter.name))")
        lines.append("description: \(self.quoteIfNeeded(document.frontmatter.description))")
        if let modelHint = document.frontmatter.modelHint, !modelHint.isEmpty {
            lines.append("model: \(self.quoteIfNeeded(modelHint))")
        }
        if !document.frontmatter.allowedTools.isEmpty {
            let joined = document.frontmatter.allowedTools
                .map(self.quoteIfNeeded)
                .joined(separator: ", ")
            lines.append("allowed-tools: [\(joined)]")
        }
        if document.frontmatter.alwaysInline {
            lines.append("always-inline: true")
        }
        if let version = document.frontmatter.version, !version.isEmpty {
            lines.append("version: \(self.quoteIfNeeded(version))")
        }
        lines.append("---")
        lines.append("")
        return lines.joined(separator: "\n") + document.body
    }

    // MARK: Private

    private static func quoteIfNeeded(_ value: String) -> String {
        // YAML scalars need quoting when they contain `:`, start
        // with a special character, or contain leading /
        // trailing whitespace. Cheap heuristic — quote on `:`,
        // newlines, `#`, or surrounding whitespace.
        let needsQuoting = value.contains(":")
            || value.contains("#")
            || value.contains("\n")
            || value != value.trimmingCharacters(in: .whitespaces)
        if needsQuoting {
            let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
