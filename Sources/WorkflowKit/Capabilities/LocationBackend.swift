import Foundation

// MARK: - LocationBackend

/// Injection seam for CoreLocation. Production
/// `LocationCapability` uses `CoreLocationBackend`; tests use
/// `InMemoryLocationBackend` so the test runner never needs
/// Location authorization.
public protocol LocationBackend: Sendable {
    /// Request foreground (when-in-use) authorization. Throws
    /// when the user denies.
    func requestAccess() async throws

    /// One-shot fix. Low-accuracy by default — workflows like the
    /// Daily Brief don't need GPS-grade precision and the lower
    /// setting is much faster and battery-cheaper.
    func currentFix() async throws -> LocationFix

    /// Forward geocoding: address string → first matching
    /// placemark. Returns `nil` when no match exists.
    func geocode(address: String) async throws -> Placemark?

    /// Reverse geocoding: coordinate → first placemark. Returns
    /// `nil` when no match exists.
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> Placemark?
}

// MARK: - LocationFix

public struct LocationFix: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracyMeters: Double,
        timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.timestamp = timestamp
    }

    // MARK: Public

    public let latitude: Double
    public let longitude: Double
    public let horizontalAccuracyMeters: Double
    public let timestamp: Date
}

// MARK: - Placemark

public struct Placemark: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        latitude: Double,
        longitude: Double,
        name: String?,
        locality: String?,
        administrativeArea: String?,
        country: String?,
        postalCode: String?
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.locality = locality
        self.administrativeArea = administrativeArea
        self.country = country
        self.postalCode = postalCode
    }

    // MARK: Public

    public let latitude: Double
    public let longitude: Double
    /// Display name — e.g. "Apple Park" for a venue, or a
    /// best-effort label for an address.
    public let name: String?
    public let locality: String?
    public let administrativeArea: String?
    public let country: String?
    public let postalCode: String?
}

// MARK: - InMemoryLocationBackend

public struct InMemoryLocationBackend: LocationBackend {
    // MARK: Lifecycle

    public init(
        fix: LocationFix = LocationFix(
            latitude: 37.331_2,
            longitude: -122.030_6,
            horizontalAccuracyMeters: 50,
            timestamp: Date()
        ),
        forwardLookup: [String: Placemark] = [:],
        reverseLookup: [String: Placemark] = [:],
        authorizationError: (any Error)? = nil
    ) {
        self.fixFixture = fix
        self.forwardLookup = forwardLookup
        self.reverseLookup = reverseLookup
        self.authorizationError = authorizationError
    }

    // MARK: Public

    /// Stable string form for the reverse-lookup keying. Tests
    /// use this same helper when seeding the fixture so a query
    /// and its fixture land at the same map key.
    public static func coordinateKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }

    // MARK: LocationBackend

    public func requestAccess() async throws {
        if let error = authorizationError {
            throw error
        }
    }

    public func currentFix() async throws -> LocationFix {
        self.fixFixture
    }

    public func geocode(address: String) async throws -> Placemark? {
        self.forwardLookup[address]
    }

    public func reverseGeocode(latitude: Double, longitude: Double) async throws -> Placemark? {
        self.reverseLookup[Self.coordinateKey(latitude: latitude, longitude: longitude)]
    }

    // MARK: Private

    private let fixFixture: LocationFix
    private let forwardLookup: [String: Placemark]
    private let reverseLookup: [String: Placemark]
    private let authorizationError: (any Error)?
}
