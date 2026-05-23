import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - FilesCapabilityTests

/// `FilesCapability` reads from user-picked URLs. We can't
/// exercise `UIDocumentPickerViewController` from a unit test, so
/// the suite writes temp files directly and feeds their `file://`
/// URLs into the capability.
struct FilesCapabilityTests {
    // MARK: Internal

    @Test
    func readTextDecodesUTF8() async throws {
        let url = try Self.makeTempFile(contents: "hello, workflow")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await FilesCapability().call(
            method: "readText",
            arguments: ["url": .string(url.absoluteString)],
            context: Self.context()
        )
        #expect(result == .string("hello, workflow"))
    }

    @Test
    func readTextAcceptsPathWithoutSchemePrefix() async throws {
        let url = try Self.makeTempFile(contents: "raw path")
        defer { try? FileManager.default.removeItem(at: url) }

        // Some callers pass the bare path (no file:// scheme);
        // capability should still resolve it.
        let result = try await FilesCapability().call(
            method: "readText",
            arguments: ["url": .string(url.path)],
            context: Self.context()
        )
        #expect(result == .string("raw path"))
    }

    @Test
    func readTextRejectsMissingArg() async {
        await #expect(throws: CapabilityError.self) {
            try await FilesCapability().call(
                method: "readText",
                arguments: [:],
                context: Self.context()
            )
        }
    }

    @Test
    func readTextSurfacesIOError() async throws {
        // URL points at a path that doesn't exist — String(contentsOf:)
        // throws, the capability passes the error up.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilesCapabilityTests-missing-\(UUID().uuidString).txt")
        await #expect(throws: (any Error).self) {
            try await FilesCapability().call(
                method: "readText",
                arguments: ["url": .string(missing.absoluteString)],
                context: Self.context()
            )
        }
    }

    @Test
    func readPDFRejectsNonPDFFile() async throws {
        let url = try Self.makeTempFile(contents: "not a pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: CapabilityError.self) {
            try await FilesCapability().call(
                method: "readPDF",
                arguments: ["url": .string(url.absoluteString)],
                context: Self.context()
            )
        }
    }

    @Test
    func unknownMethodThrows() async {
        await #expect(throws: CapabilityError.self) {
            try await FilesCapability().call(
                method: "writeText",
                arguments: ["url": .string("file:///tmp/x")],
                context: Self.context()
            )
        }
    }

    // MARK: Private

    // MARK: - Helpers

    private static func makeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilesCapabilityTests-\(UUID().uuidString).txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: "sdk.builtin.test",
            callerWorkflowID: nil,
            attended: true
        )
    }
}
