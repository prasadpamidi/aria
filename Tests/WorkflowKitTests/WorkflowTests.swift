import Foundation
import Testing
@testable import WorkflowKit

// MARK: - WorkflowTests

/// Round-trip coverage for the top-level `Workflow` record + the
/// `WorkflowCodec` helpers. The two go together because the codec
/// is the only surface that touches encoder/decoder configuration
/// (date strategy, pretty-printing) — testing them as one pair
/// pins the storage contract.
struct WorkflowTests {
    // MARK: Internal

    @Test
    func workflowRoundTrip() throws {
        let workflow = Self.sampleDailyBriefShape()
        let encoded = try WorkflowCodec.encode(workflow)
        let decoded = try WorkflowCodec.decode(encoded)
        #expect(decoded == workflow)
        #expect(decoded.nodes.count == 3)
        #expect(decoded.triggers == [.manual, .shortcuts])
    }

    @Test
    func prettyExportIsStableForDiffs() throws {
        // Two prettyEncode calls on the same workflow must produce
        // byte-identical output. If they don't, version control
        // diffs of shared workflows would churn even when nothing
        // changed.
        let workflow = Self.sampleDailyBriefShape()
        let first = try WorkflowCodec.exportData(workflow)
        let second = try WorkflowCodec.exportData(workflow)
        #expect(first == second, "pretty-encode is non-deterministic — diffs will churn")
    }

    @Test
    func roundTripViaTempFile() throws {
        let workflow = Self.sampleDailyBriefShape()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowTests-\(UUID().uuidString).workflow.json")
        defer { try? FileManager.default.removeItem(at: url) }

        try WorkflowCodec.write(workflow, to: url)
        let restored = try WorkflowCodec.read(from: url)
        #expect(restored == workflow)
    }

    @Test
    func decodeRejectsBogusPayload() {
        let bogus = Data("{\"name\": 42}".utf8)
        #expect(throws: DecodingError.self) {
            _ = try WorkflowCodec.decode(bogus)
        }
    }

    // MARK: Private

    // MARK: - Sample

    /// Shape-only sketch of the Daily Brief flow. The real
    /// template lands in slice 15; this stub gives later slices
    /// a stable fixture without crystallising its content.
    private static func sampleDailyBriefShape() -> Workflow {
        let fetchEvents = CapabilityStep(
            capability: .calendar,
            method: "eventsToday",
            outputBinding: "events"
        )
        let summarise = LLMStep(
            promptTemplate: "Narrate a morning brief covering {{step1.events}}.",
            modelHint: .foundationModels
        )
        let render = OutputStep(fields: [
            "spoken_text": "{{step2.text}}",
        ])
        return Workflow(
            name: "Daily Brief",
            summary: "Morning narration of today's events.",
            outputSchema: OutputSchema(fields: [
                OutputField(id: "spoken_text", label: "Spoken text"),
            ]),
            nodes: [
                .capability(fetchEvents),
                .llm(summarise),
                .output(render),
            ],
            triggers: [.manual, .shortcuts],
            modelHint: .foundationModels,
            toolPolicy: ToolPolicy(allowedCapabilities: [.calendar]),
            memoryPolicy: MemoryPolicy(mode: .isolated, threadId: "daily-brief")
        )
    }
}
