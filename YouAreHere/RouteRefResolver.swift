import Foundation
import CoreLocation

/// Resolves the numbered route carried by the road at a coordinate, for the
/// common case where Apple's geocoder returns only the local street name
/// (e.g. "St George Rd") and omits that it's also a state route (ME-131).
///
/// Abstracted so the bundled offline dataset can later implement the same
/// protocol; today it's backed by OpenStreetMap via the Overpass API (online,
/// opt-in — it sends the coordinate to a third-party server).
protocol RouteRefResolver {
    func routeRef(near location: CLLocation) async throws -> RouteRef?
}

/// Looks up the nearest road's OSM `ref` tag (e.g. "ME 131", "US 1", "I 80")
/// via Overpass and parses it into a `RouteRef`.
///
/// Usage is deliberately sparse — `LocationEngine` only calls this when the road
/// *changes* and Apple didn't already supply a route — to stay well within
/// Overpass's fair-use limits.
struct OverpassRouteResolver: RouteRefResolver {
    /// Search radius in meters around the coordinate.
    private let radius = 40
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    func routeRef(near location: CLLocation) async throws -> RouteRef? {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        // Ways tagged as roads that carry a route number, with geometry so we can
        // pick the nearest one.
        let query = """
        [out:json][timeout:8];way(around:\(radius),\(lat),\(lon))[highway][ref];out tags geom;
        """

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data("data=\(encoded)".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Identify the app, per Overpass etiquette.
        req.setValue("YouAreHere/1.0 (iOS wayfinding app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil   // rate-limited / unavailable: just fall back silently
        }

        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)

        // Pick the way whose geometry passes closest to us and whose ref parses.
        var best: (dist: CLLocationDistance, ref: RouteRef)?
        for element in decoded.elements {
            guard let ref = element.tags?.ref,
                  let parsed = parse(osmRef: ref) else { continue }
            let d = element.minDistance(to: location)
            if best == nil || d < best!.dist {
                best = (d, parsed)
            }
        }
        return best?.ref
    }

    /// Parse an OSM `ref` value. These are space-separated ("ME 131", "US 1",
    /// "I 80") and may list several routes ("US 1;ME 131"). We reuse the app's
    /// `RouteParser`, which already understands these forms and prefers
    /// Interstate > US > state when more than one is present.
    private func parse(osmRef: String) -> RouteRef? {
        for candidate in osmRef.split(separator: ";") {
            if let r = RouteParser.parse(road: String(candidate), stateAbbrev: nil) {
                return r
            }
        }
        return RouteParser.parse(road: osmRef, stateAbbrev: nil)
    }
}

// MARK: - Overpass JSON

private struct OverpassResponse: Decodable {
    let elements: [Element]
}

private struct Element: Decodable {
    struct Tags: Decodable { let ref: String? }
    struct Coord: Decodable { let lat: Double; let lon: Double }
    let tags: Tags?
    let geometry: [Coord]?

    /// Closest distance from the way's vertices to the given location. Overpass
    /// returns dense geometry, so vertex distance is a fine proxy for the
    /// point-to-polyline distance here.
    func minDistance(to location: CLLocation) -> CLLocationDistance {
        guard let geometry, !geometry.isEmpty else { return .greatestFiniteMagnitude }
        return geometry
            .map { CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: location) }
            .min() ?? .greatestFiniteMagnitude
    }
}
