import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - LocationCapabilityTests

struct LocationCapabilityTests {
    // MARK: Internal

    @Test
    func currentReturnsFixObject() async throws {
        let fixTime = Date(timeIntervalSince1970: 1_800_000_000)
        let backend = InMemoryLocationBackend(fix: LocationFix(
            latitude: 37.331_2,
            longitude: -122.030_6,
            horizontalAccuracyMeters: 15,
            timestamp: fixTime
        ))

        let capability = LocationCapability(backend: backend)
        let result = try await capability.call(
            method: "current",
            arguments: [:],
            context: Self.context()
        )

        guard case let .object(dict) = result else {
            Issue.record("Expected an object, got \(result)")
            return
        }
        #expect(dict["latitude"] == .number(37.331_2))
        #expect(dict["longitude"] == .number(-122.030_6))
        #expect(dict["accuracyMeters"] == .number(15))
        #expect(dict["timestamp"] != nil)
    }

    @Test
    func geocodeReturnsPlacemarkFromForwardLookup() async throws {
        let backend = InMemoryLocationBackend(
            forwardLookup: [
                "Apple Park": Placemark(
                    latitude: 37.334_9,
                    longitude: -122.008_9,
                    name: "Apple Park",
                    locality: "Cupertino",
                    administrativeArea: "CA",
                    country: "United States",
                    postalCode: "95014"
                ),
            ]
        )

        let capability = LocationCapability(backend: backend)
        let result = try await capability.call(
            method: "geocode",
            arguments: ["address": .string("Apple Park")],
            context: Self.context()
        )

        guard case let .object(dict) = result else {
            Issue.record("Expected an object, got \(result)")
            return
        }
        #expect(dict["name"] == .string("Apple Park"))
        #expect(dict["locality"] == .string("Cupertino"))
        #expect(dict["country"] == .string("United States"))
    }

    @Test
    func geocodeReturnsNullOnNoMatch() async throws {
        let capability = LocationCapability(backend: InMemoryLocationBackend())
        let result = try await capability.call(
            method: "geocode",
            arguments: ["address": .string("Not a real address")],
            context: Self.context()
        )
        #expect(result == .null)
    }

    @Test
    func reverseGeocodeUsesCoordinateKey() async throws {
        let key = InMemoryLocationBackend.coordinateKey(
            latitude: 37.331_2,
            longitude: -122.030_6
        )
        let backend = InMemoryLocationBackend(
            reverseLookup: [
                key: Placemark(
                    latitude: 37.331_2,
                    longitude: -122.030_6,
                    name: nil,
                    locality: "Cupertino",
                    administrativeArea: "CA",
                    country: "United States",
                    postalCode: "95014"
                ),
            ]
        )

        let capability = LocationCapability(backend: backend)
        let result = try await capability.call(
            method: "reverseGeocode",
            arguments: [
                "latitude": .number(37.331_2),
                "longitude": .number(-122.030_6),
            ],
            context: Self.context()
        )

        guard case let .object(dict) = result else {
            Issue.record("Expected an object, got \(result)")
            return
        }
        #expect(dict["locality"] == .string("Cupertino"))
        // `name` was nil → omitted from encoding.
        #expect(dict["name"] == nil)
    }

    @Test
    func geocodeRequiresAddressArg() async {
        let capability = LocationCapability(backend: InMemoryLocationBackend())
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "geocode",
                arguments: [:],
                context: Self.context()
            )
        }
    }

    @Test
    func reverseGeocodeRequiresNumericCoordinates() async {
        let capability = LocationCapability(backend: InMemoryLocationBackend())
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "reverseGeocode",
                arguments: ["latitude": .string("not a number")],
                context: Self.context()
            )
        }
    }

    @Test
    func unknownMethodThrows() async {
        let capability = LocationCapability(backend: InMemoryLocationBackend())
        await #expect(throws: CapabilityError.self) {
            try await capability.call(
                method: "futureMethod",
                arguments: [:],
                context: Self.context()
            )
        }
    }

    @Test
    func authorizationFailureSurfacesAsUnavailable() async {
        struct DummyError: Error { }
        let capability = LocationCapability(
            backend: InMemoryLocationBackend(authorizationError: DummyError())
        )
        await #expect {
            try await capability.call(
                method: "current",
                arguments: [:],
                context: Self.context()
            )
        } throws: { error in
            guard let capabilityError = error as? CapabilityError,
                  case .unavailable = capabilityError else {
                return false
            }
            return true
        }
    }

    // MARK: Private

    private static func context() -> CapabilityCallContext {
        CapabilityCallContext(
            callerPluginID: "sdk.builtin.test",
            callerWorkflowID: nil,
            attended: true
        )
    }
}
