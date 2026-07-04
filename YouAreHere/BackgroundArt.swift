import SwiftUI
import Combine
import CoreLocation

/// The app-screen hosts for the aesthetic backdrops: these animate smoothly
/// and own the data fetching; the drawing itself lives in
/// `BackgroundArtRenderer` (Shared) so PiP frames and the Live Activity can
/// render the same scenes statically.
struct BackgroundArtView: View {
    let kind: BackgroundArt

    var body: some View {
        switch kind {
        case .off:     EmptyView()
        case .streets: StreetsBackground()
        case .topo:    TopoBackground()
        case .neon:    NeonBackground()
        }
    }
}

// MARK: - Streets (Overpass geometry, tilted like an idle nav display)

/// Fetches nearby road geometry from Overpass, sparsely: once on the first
/// fix, then only after moving ~300m, never more often than every 2 minutes.
/// Shared singleton so the PiP frame renderer can draw the same map.
@MainActor
final class StreetMapModel: ObservableObject {
    static let shared = StreetMapModel()

    @Published private(set) var roads: [RoadStroke] = []

    private var center: CLLocationCoordinate2D?
    private var lastFetch = Date.distantPast
    private var inFlight = false
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    func update(for coordinate: CLLocationCoordinate2D) {
        guard !inFlight else { return }
        let movedEnough = center.map {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) > 300
        } ?? true
        // Sparse by design (fair use): 2 min between refreshes once we have a
        // map; a gentler 20s retry while we're still waiting for the first one.
        guard movedEnough,
              Date().timeIntervalSince(lastFetch) > (center == nil ? 20 : 120) else { return }

        inFlight = true
        lastFetch = Date()
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.inFlight = false } }
            let roads = await Self.fetch(around: coordinate, endpoint: self.endpoint)
            guard let roads else { return }   // network blip: keep what we had
            await MainActor.run {
                self.center = coordinate
                self.roads = roads
            }
        }
    }

    private static func fetch(around coordinate: CLLocationCoordinate2D,
                              endpoint: URL) async -> [RoadStroke]? {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let query = """
        [out:json][timeout:10];way(around:600,\(lat),\(lon))[highway]\
        [highway!~"footway|path|cycleway|steps|pedestrian|bridleway|construction|proposed"];\
        out geom 600;
        """
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data("data=\(encoded)".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("YouAreHere/1.0 (iOS wayfinding app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(GeomResponse.self, from: data) else { return nil }

        // Equirectangular projection is plenty at a 1km radius.
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = metersPerDegLat * cos(lat * .pi / 180)
        return decoded.elements.compactMap { el in
            guard let geom = el.geometry, geom.count >= 2 else { return nil }
            let pts = geom.map {
                CGPoint(x: ($0.lon - lon) * metersPerDegLon,
                        y: -($0.lat - lat) * metersPerDegLat)
            }
            let kind = el.tags?.highway ?? ""
            let major = kind.hasPrefix("motorway") || kind.hasPrefix("trunk") || kind.hasPrefix("primary")
            return RoadStroke(points: pts, major: major)
        }
    }

    private struct GeomResponse: Decodable {
        struct Element: Decodable {
            struct Tags: Decodable { let highway: String? }
            struct Coord: Decodable { let lat: Double; let lon: Double }
            let tags: Tags?
            let geometry: [Coord]?
        }
        let elements: [Element]
    }
}

/// The Sentra-idle look: nearby roads as faint strokes on a plane tilted away
/// from the viewer, rotating imperceptibly, fading out toward the horizon.
struct StreetsBackground: View {
    @EnvironmentObject private var engine: LocationEngine
    @ObservedObject private var model = StreetMapModel.shared
    @AppStorage(SettingsKey.backgroundContrast) private var contrast = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            Canvas { ctx, size in
                BackgroundArtRenderer.drawStreets(
                    &ctx, size: size, roads: model.roads,
                    angle: BackgroundArtRenderer.streetsAutoAngle(at: timeline.date),
                    contrast: contrast)
            }
        }
        // Tip the map plane away like an idle nav display, then fade the far
        // edge into the background so it reads as horizon, not clutter.
        .rotation3DEffect(.degrees(46), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
        .scaleEffect(1.9)
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .white, location: 0.45)],
                           startPoint: .top, endPoint: .bottom)
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onReceive(engine.$lastCoordinate.compactMap { $0 }) { coordinate in
            model.update(for: coordinate)
        }
    }
}

// MARK: - Topo (procedural contour lines)

/// Reference-type cache mutated inside the Canvas draw closure: the path is
/// built lazily on the first draw with the canvas's *actual* size, which
/// sidesteps GeometryReader first-layout races entirely.
private final class TopoCache {
    var size = CGSize.zero
    var path = Path()
}

struct TopoBackground: View {
    @State private var cache = TopoCache()
    @AppStorage(SettingsKey.backgroundContrast) private var contrast = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            Canvas { ctx, size in
                if cache.size != size {
                    cache.size = size
                    cache.path = BackgroundArtRenderer.topoContours(size: size)
                }
                BackgroundArtRenderer.drawTopo(&ctx, size: size, path: cache.path,
                                               date: timeline.date, contrast: contrast)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Neon (synthwave grid; scroll speed follows GPS speed)

/// The outrun look. The grid's scroll rate follows GPS ground speed
/// (low-passed so it breathes rather than jumps), with a slow idle crawl at
/// rest. Dark mode only (ContentView gates it).
struct NeonBackground: View {
    @EnvironmentObject private var engine: LocationEngine
    @State private var phase = 0.0           // grid scroll, wraps every row
    @State private var smoothedSpeed = 0.0   // m/s, low-passed
    @State private var lastTick: Date?
    @AppStorage(SettingsKey.backgroundContrast) private var contrast = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 24)) { timeline in
            Canvas { ctx, size in
                BackgroundArtRenderer.drawNeon(&ctx, size: size, phase: phase, contrast: contrast)
            }
            .onChange(of: timeline.date) { now in
                let dt = lastTick.map { min(now.timeIntervalSince($0), 0.5) } ?? 0
                lastTick = now
                // Ease toward the current GPS speed over ~half a second.
                smoothedSpeed += (engine.speedMPS - smoothedSpeed) * min(1, dt * 2)
                // Idle crawl + speed: ~65 mph ≈ 2.4 grid rows/second.
                let rowsPerSecond = 0.12 + smoothedSpeed * 0.08
                phase = (phase + rowsPerSecond * dt).truncatingRemainder(dividingBy: 1)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

#Preview("Topo") {
    ZStack {
        Theme.background.ignoresSafeArea()
        TopoBackground()
    }
}
