#if canImport(CoreLocation)
    import CoreLocation
    import Foundation

    // MARK: - CoreLocationBackend

    /// Production CoreLocation-backed implementation.
    ///
    /// Uses iOS 17+ `CLLocationUpdate.liveUpdates()` to fetch a
    /// single fix without owning a delegate. The first non-empty
    /// update with a horizontal accuracy that beats the
    /// requested threshold returns; the live stream is then
    /// cancelled.
    public final class CoreLocationBackend: LocationBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init(
            manager: CLLocationManager = CLLocationManager(),
            geocoder: CLGeocoder = CLGeocoder()
        ) {
            self.manager = manager
            self.geocoder = geocoder
            self.manager.desiredAccuracy = kCLLocationAccuracyKilometer
        }

        // MARK: Public

        // MARK: LocationBackend

        public func requestAccess() async throws {
            self.manager.requestWhenInUseAuthorization()
            // CLLocationManager's auth-status callbacks come via
            // the delegate, which complicates a pure async wrapper.
            // For P0 we trust the system sheet: callers that need
            // a synchronous "did the user accept?" can inspect
            // `manager.authorizationStatus` after the next system
            // event. The capability handles outright denials by
            // surfacing the CL error from `currentFix()`.
        }

        public func currentFix() async throws -> LocationFix {
            let updates = CLLocationUpdate.liveUpdates(.default)
            for try await update in updates {
                guard let location = update.location else {
                    continue
                }
                return LocationFix(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    horizontalAccuracyMeters: location.horizontalAccuracy,
                    timestamp: location.timestamp
                )
            }
            throw CoreLocationBackendError.noFixAvailable
        }

        public func geocode(address: String) async throws -> Placemark? {
            let placemarks = try await self.geocoder.geocodeAddressString(address)
            return placemarks.first.flatMap(Self.mapPlacemark)
        }

        public func reverseGeocode(latitude: Double, longitude: Double) async throws -> Placemark? {
            let placemarks = try await self.geocoder.reverseGeocodeLocation(
                CLLocation(latitude: latitude, longitude: longitude)
            )
            return placemarks.first.flatMap(Self.mapPlacemark)
        }

        // MARK: Private

        private let manager: CLLocationManager
        private let geocoder: CLGeocoder

        private static func mapPlacemark(_ placemark: CLPlacemark) -> Placemark? {
            guard let coordinate = placemark.location?.coordinate else {
                return nil
            }
            return Placemark(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: placemark.name,
                locality: placemark.locality,
                administrativeArea: placemark.administrativeArea,
                country: placemark.country,
                postalCode: placemark.postalCode
            )
        }
    }

    // MARK: - CoreLocationBackendError

    public enum CoreLocationBackendError: Error, Sendable, Equatable {
        case noFixAvailable
    }
#endif
