import Foundation
import CoreLocation

/// What we can learn about the road at a coordinate from a road-network source:
/// its numbered route (for the shield) and its posted speed limit.
struct RoadInfo {
    var route: RouteRef? = nil
    /// Posted speed limit, normalized to km/h. nil when unknown.
    var speedLimitKmh: Double? = nil
}

/// Resolves `RoadInfo` for a coordinate, for the cases Apple's geocoder can't
/// cover: it has no field for a road's route number *or* its speed limit.
///
/// Abstracted so a bundled offline dataset can later implement the same
/// protocol; today it's backed by OpenStreetMap via the Overpass API (online,
/// opt-in — it sends the coordinate to a third-party server).
protocol RoadInfoResolver {
    func roadInfo(near location: CLLocation) async throws -> RoadInfo
}

/// Reads the nearest drivable OSM way and pulls its `ref` (route number) and
/// `maxspeed` (speed limit) tags via Overpass.
///
/// Usage is deliberately sparse — `LocationEngine` only calls this when the road
/// *changes* — to stay well within Overpass's fair-use limits.
struct OverpassRoadInfoResolver: RoadInfoResolver {
    /// Search radius in meters around the coordinate.
    private let radius = 40
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    func roadInfo(near location: CLLocation) async throws -> RoadInfo {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        // Nearby drivable ways (exclude paths/footways/etc.), with geometry so we
        // can pick the one we're actually on.
        let query = """
        [out:json][timeout:8];way(around:\(radius),\(lat),\(lon))[highway]\
        [highway!~"footway|path|cycleway|steps|pedestrian|bridleway|track|construction|proposed"];\
        out tags geom;
        """

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data("data=\(encoded)".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("YouAreHere/1.0 (iOS wayfinding app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return RoadInfo()   // rate-limited / unavailable: fall back silently
        }

        let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)

        // The way whose geometry passes closest to us is the road we're on.
        var nearest: (dist: CLLocationDistance, el: Element)?
        for element in decoded.elements where element.geometry?.isEmpty == false {
            let d = element.minDistance(to: location)
            if nearest == nil || d < nearest!.dist { nearest = (d, element) }
        }
        guard let tags = nearest?.el.tags else { return RoadInfo() }

        return RoadInfo(route: tags.ref.flatMap(parse(osmRef:)),
                        speedLimitKmh: tags.maxspeed.flatMap(parseMaxspeed))
    }

    /// Parse an OSM `ref` ("ME 131", "US 1", "I 80"); may list several
    /// ("US 1;ME 131"). Reuses `RouteParser`, which prefers Interstate > US >
    /// state when more than one is present.
    private func parse(osmRef: String) -> RouteRef? {
        for candidate in osmRef.split(separator: ";") {
            if let r = RouteParser.parse(road: String(candidate), stateAbbrev: nil) { return r }
        }
        return RouteParser.parse(road: osmRef, stateAbbrev: nil)
    }

    /// Parse an OSM `maxspeed` value to km/h. Handles "45 mph", "50", "30 mph",
    /// "60 km/h"; returns nil for "none", "signals", "walk", "variable", etc.
    private func parseMaxspeed(_ raw: String) -> Double? {
        let s = raw.lowercased()
        // First integer in the string.
        var digits = ""
        for ch in s { if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break } }
        guard let value = Double(digits), value > 0 else { return nil }
        // OSM convention: bare numbers are km/h; "mph" is explicit.
        if s.contains("mph") { return value * 1.60934 }
        return value
    }
}

// MARK: - Overpass JSON

private struct OverpassResponse: Decodable {
    let elements: [Element]
}

private struct Element: Decodable {
    struct Tags: Decodable {
        let ref: String?
        let maxspeed: String?
    }
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
