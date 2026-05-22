import Foundation
import Testing
@testable import WorkflowKit

// MARK: - WorkflowEnumsTests

/// Codable round-trip coverage for every enum + schema type in
/// `WorkflowEnums.swift`. The model is the long-term storage
/// format (workflows persist as JSON in GRDB; users can also
/// import/export individual `.workflow.json` files), so a tight
/// round-trip suite is the firewall against silent schema drift.
///
/// Convention: encode → decode → assert equality. Every test
/// instantiates a non-default sample (not the `.init()` empty
/// shape) so a missing-field bug surfaces as a decode mismatch
/// rather than a vacuous pass.
struct WorkflowEnumsTests {
    // MARK: - CapabilityID

    @Test
    func capabilityIDRoundTrip() throws {
        for cap in CapabilityID.allCases {
            let encoded = try JSONEncoder().encode(cap)
            let decoded = try JSONDecoder().decode(CapabilityID.self, from: encoded)
            #expect(decoded == cap, "round-trip drift for \(cap)")
        }
    }

    @Test
    func capabilityIDIsStableJSON() throws {
        // Stable string form is part of the storage contract — if
        // someone renames a case in the future, this test will
        // fail and force them to consider migration.
        let encoded = try JSONEncoder().encode(CapabilityID.secrets)
        let json = String(data: encoded, encoding: .utf8)
        #expect(json == "\"secrets\"")
    }

    // MARK: - Trigger

    @Test
    func triggerRoundTrip() throws {
        let triggers: Set<Trigger> = [.manual, .shortcuts, .urlScheme]
        let encoded = try JSONEncoder().encode(triggers)
        let decoded = try JSONDecoder().decode(Set<Trigger>.self, from: encoded)
        #expect(decoded == triggers)
    }

    // MARK: - ModelFamilyHint

    @Test
    func modelFamilyHintRoundTrip() throws {
        let hint = ModelFamilyHint.foundationModels
        let encoded = try JSONEncoder().encode(hint)
        let decoded = try JSONDecoder().decode(ModelFamilyHint.self, from: encoded)
        #expect(decoded == hint)
    }

    // MARK: - InputSchema

    @Test
    func inputSchemaRoundTrip() throws {
        let schema = InputSchema(fields: [
            InputField(id: "city", label: "City", kind: .text, optional: true),
            InputField(id: "when", label: "When", kind: .date, optional: false),
            InputField(id: "limit", label: "Limit", kind: .number, optional: true),
            InputField(id: "loud", label: "Loud?", kind: .bool, optional: true),
        ])
        let encoded = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(InputSchema.self, from: encoded)
        #expect(decoded == schema)
        #expect(decoded.fields.count == 4)
    }

    // MARK: - OutputSchema

    @Test
    func outputSchemaRoundTrip() throws {
        let schema = OutputSchema(fields: [
            OutputField(id: "spoken_text", label: "Spoken text"),
            OutputField(id: "headline", label: "Headline"),
        ])
        let encoded = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(OutputSchema.self, from: encoded)
        #expect(decoded == schema)
        #expect(decoded.fields.map(\.id) == ["spoken_text", "headline"])
    }
}
