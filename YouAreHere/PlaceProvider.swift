import Foundation
import CoreLocation

/// The resolved place for a coordinate.
struct ResolvedPlace: Equatable {
    var town: String
    var road: String
    var route: RouteRef?
    /// State/province abbreviation, used for state-route shields.
    var stateAbbrev: String?
}

/// Abstraction over "coordinate → place name" so we can swap implementations.
///
/// Today this is backed by Apple's online `CLGeocoder`. When you're ready to
/// add offline naming (a bundled OSM-derived gazetteer), implement this
/// protocol and have `LocationEngine` fall back to it when `hasNetwork` is
/// false — nothing else has to change.
protocol PlaceProvider {
    /// Whether this provider needs the network to answer.
    var requiresNetwork: Bool { get }
    func resolve(_ location: CLLocation) async throws -> ResolvedPlace
}

/// Apple reverse geocoding. Requires a network connection.
///
/// Note: `CLGeocoder` is rate-limited by Apple — it's meant for occasional
/// lookups, not once per second. `LocationEngine` therefore only calls this
/// when the device has moved a meaningful distance (or after a cooldown), and
/// never with more than one request in flight.
final class AppleGeocoder: PlaceProvider {
    let requiresNetwork = true
    private let geocoder = CLGeocoder()

    func resolve(_ location: CLLocation) async throws -> ResolvedPlace {
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        guard let p = placemarks.first else {
            throw CLError(.geocodeFoundNoResult)
        }

        let town = p.locality
            ?? p.subLocality
            ?? p.subAdministrativeArea
            ?? p.administrativeArea
            ?? ""

        let road = p.thoroughfare
            ?? (p.areasOfInterest?.first)
            ?? ""

        let stateAbbrev = stateAbbreviation(from: p)
        let route = RouteParser.parse(road: road, stateAbbrev: stateAbbrev)

        return ResolvedPlace(town: town, road: road, route: route, stateAbbrev: stateAbbrev)
    }

    /// `administrativeArea` is usually already an abbreviation in the US ("CA"),
    /// but can be a full name elsewhere; pass through as-is.
    private func stateAbbreviation(from placemark: CLPlacemark) -> String? {
        guard let admin = placemark.administrativeArea else { return nil }
        return admin
    }
}
