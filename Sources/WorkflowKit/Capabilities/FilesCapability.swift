import Aria
import Foundation

#if canImport(PDFKit)
    import PDFKit
#endif

// MARK: - FilesCapability

/// Read-only access to files the user has explicitly picked
/// (via `UIDocumentPickerViewController` or any other system
/// surface that vends a security-scoped URL).
///
/// This capability deliberately does NOT enumerate the
/// filesystem — there is no `listDocuments()` method. Every
/// readable path arrives from a user gesture, which keeps the
/// consent model trivial (the picker IS the consent).
///
/// Two methods:
///
///   * `readText(url)` — UTF-8 decode of any text file the URL
///     points to.
///   * `readPDF(url)`  — concatenated visible text from a PDF
///     via PDFKit. Stripped of common page-header / page-footer
///     noise is *not* part of P0 — the model gets the raw
///     concat and is good at handling residual noise.
///
/// Both methods accept the URL as a `file://...` string in the
/// `url` argument. The capability opens a security-scoped
/// resource for the duration of the read.
public actor FilesCapability: Capability {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .files
    }

    public nonisolated var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        switch method {
        case "readText":
            return try self.handleReadText(arguments: arguments)
        case "readPDF":
            return try self.handleReadPDF(arguments: arguments)
        default:
            throw CapabilityError.unknownMethod(capability: .files, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = [
        "readText",
        "readPDF",
    ]

    // MARK: Private

    /// Open a security-scoped resource for the duration of
    /// `body`, regardless of whether `body` throws. UIDocumentPicker
    /// URLs require this dance — outside the scope, the URL is
    /// non-readable.
    private static func withScopedAccess<Result>(
        _ url: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        // Security-scoped resource access is Apple-only — the
        // UIDocumentPicker / NSOpenPanel sandboxing dance doesn't
        // exist on Linux, so we no-op the scope-management calls
        // there. Apple builds keep the original semantics intact.
        #if canImport(Darwin)
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started {
                    url.stopAccessingSecurityScopedResource()
                }
            }
        #endif
        return try body()
    }

    private static func requireURLArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> URL {
        guard case let .string(string) = arguments[key] ?? .null else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string (file URL)",
                actual: String(describing: arguments[key] ?? .null)
            )
        }
        // Accept three input shapes for caller convenience:
        //   1. "file:///private/var/foo/bar.txt" — canonical
        //   2. "/private/var/foo/bar.txt"        — bare absolute
        //   3. Any other URL the caller can parse to a file URL
        // For shape 2, `URL(string:)` parses but produces a URL
        // with no scheme, which `String(contentsOf:)` rejects.
        // Resolve via `URL(fileURLWithPath:)` instead.
        if string.hasPrefix("/") {
            return URL(fileURLWithPath: string)
        }
        guard let url = URL(string: string) else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "valid file URL",
                actual: string
            )
        }
        return url
    }

    private func handleReadText(arguments: [String: JSONValue]) throws -> JSONValue {
        let url = try Self.requireURLArg("url", from: arguments, method: "readText")
        let text = try Self.withScopedAccess(url) {
            try String(contentsOf: url, encoding: .utf8)
        }
        return .string(text)
    }

    private func handleReadPDF(arguments: [String: JSONValue]) throws -> JSONValue {
        let url = try Self.requireURLArg("url", from: arguments, method: "readPDF")
        #if canImport(PDFKit)
            let text = try Self.withScopedAccess(url) { () throws -> String in
                guard let document = PDFDocument(url: url) else {
                    throw CapabilityError.invalidArguments(
                        method: "readPDF",
                        expected: "URL pointing at a PDF",
                        actual: url.path
                    )
                }
                var out = ""
                for pageIndex in 0..<document.pageCount {
                    if let page = document.page(at: pageIndex),
                       let pageText = page.string {
                        out.append(pageText)
                        out.append("\n")
                    }
                }
                return out
            }
            return .string(text)
        #else
            throw CapabilityError.unavailable(reason: "PDFKit not available on this platform")
        #endif
    }
}
