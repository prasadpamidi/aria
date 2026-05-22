import Aria
import Foundation

// MARK: - LocationCapability

/// CoreLocation-backed reader for the Daily Brief's "where am I"
/// piece + ad-hoc geocoding from workflows like a weather
/// plugin's "look up coords for this city."
///
/// Three methods:
///   * `current()` — one-shot fix at low accuracy. Returns
///     `{ latitude, longitude, accuracyMeters, timestamp }`.
///   * `geocode(address)` — forward geocode. `null` on no match.
///   * `reverseGeocode(latitude, longitude)` — reverse geocode.
///     `null` on no match.
public actor LocationCapability: Capability {
    // MARK: Lifecycle

    public init(backend: any LocationBackend) {
        self.backend = backend
    }

    // MARK: Public

    // MARK: Capability

    public nonisolated var id: CapabilityID {
        .location
    }

    public nonisolated var supportedMethods: Set<String> {
        Self.allMethods
    }

    public func call(
        method: String,
        arguments: [String: JSONValue],
        context _: CapabilityCallContext
    ) async throws -> JSONValue {
        try await self.ensureAuthorized()
        switch method {
        case "current":
            return try await self.handleCurrent()
        case "geocode":
            return try await self.handleGeocode(arguments: arguments)
        case "reverseGeocode":
            return try await self.handleReverseGeocode(arguments: arguments)
        default:
            throw CapabilityError.unknownMethod(capability: .location, method: method)
        }
    }

    // MARK: Internal

    static let allMethods: Set<String> = [
        "current",
        "geocode",
        "reverseGeocode",
    ]

    // MARK: Private

    private static nonisolated(unsafe) let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let backend: any LocationBackend
    private var didRequestAccess = false

    private static func encodePlacemark(_ placemark: Placemark?) -> JSONValue {
        guard let placemark else {
            return .null
        }
        var object: [String: JSONValue] = [
            "latitude": .number(placemark.latitude),
            "longitude": .number(placemark.longitude),
        ]
        if let name = placemark.name {
            object["name"] = .string(name)
        }
        if let locality = placemark.locality {
            object["locality"] = .string(locality)
        }
        if let admin = placemark.administrativeArea {
            object["administrativeArea"] = .string(admin)
        }
        if let country = placemark.country {
            object["country"] = .string(country)
        }
        if let postalCode = placemark.postalCode {
            object["postalCode"] = .string(postalCode)
        }
        return .object(object)
    }

    private static func requireStringArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> String {
        guard case let .string(string) = arguments[key] ?? .null else {
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type string",
                actual: String(describing: arguments[key] ?? .null)
            )
        }
        return string
    }

    private static func requireDoubleArg(
        _ key: String,
        from arguments: [String: JSONValue],
        method: String
    ) throws -> Double {
        switch arguments[key] {
        case let .number(double): return double
        case let .integer(int): return Double(int)
        default:
            throw CapabilityError.invalidArguments(
                method: method,
                expected: "argument '\(key)' of type number",
                actual: String(describing: arguments[key] ?? .null)
            )
        }
    }

    private func ensureAuthorized() async throws {
        guard !self.didRequestAccess else {
            return
        }
        do {
            try await self.backend.requestAccess()
            self.didRequestAccess = true
        } catch {
            throw CapabilityError.unavailable(reason: String(describing: error))
        }
    }

    private func handleCurrent() async throws -> JSONValue {
        let fix = try await self.backend.currentFix()
        return .object([
            "latitude": .number(fix.latitude),
            "longitude": .number(fix.longitude),
            "accuracyMeters": .number(fix.horizontalAccuracyMeters),
            "timestamp": .string(Self.iso8601Formatter.string(from: fix.timestamp)),
        ])
    }

    private func handleGeocode(arguments: [String: JSONValue]) async throws -> JSONValue {
        let address = try Self.requireStringArg("address", from: arguments, method: "geocode")
        let placemark = try await self.backend.geocode(address: address)
        return Self.encodePlacemark(placemark)
    }

    private func handleReverseGeocode(arguments: [String: JSONValue]) async throws -> JSONValue {
        let lat = try Self.requireDoubleArg("latitude", from: arguments, method: "reverseGeocode")
        let lng = try Self.requireDoubleArg("longitude", from: arguments, method: "reverseGeocode")
        let placemark = try await self.backend.reverseGeocode(latitude: lat, longitude: lng)
        return Self.encodePlacemark(placemark)
    }
}
