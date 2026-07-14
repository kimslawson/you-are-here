import SwiftUI
import Combine
import CoreLocation

/// The app-screen hosts for the aesthetic backdrops: these animate smoothly
/// and own the data fetching; the drawing itself lives in
/// `BackgroundArtRenderer` (Shared) so PiP frames and the Live Activity can
/// render the same scenes statically.
struct BackgroundArtView: View {
    let kind: BackgroundArt
    /// The trail Slope/Route draw: the live recording, or a saved route during
    /// playback. Owned by ContentView.
    var track: TrackLog
    /// Slope / Route only: the scrubbed playhead on the trail's active-time
    /// axis (nil = live), owned by ContentView where the pan gesture lives.
    var slopeSelected: TimeInterval?
    /// Route only: pinch-zoom factor (1 = whole route fit to view).
    var routeZoom: CGFloat = 1

    var body: some View {
        switch kind {
        case .off:        EmptyView()
        case .streets:    StreetsBackground()
        case .topo:       TopoBackground()
        case .procedural: ProceduralBackground()
        case .neon:       NeonBackground()
        case .slope:      SlopeBackground(track: track, selected: slopeSelected)
        case .route:      RouteBackground(track: track, selected: slopeSelected, zoom: routeZoom)
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

// MARK: - Topo (real elevation contours, fetched)

/// Fetches a coarse elevation grid around the coordinate from Open-Meteo (no
/// key, free), runs marching squares over a bilinear interpolation of it, and
/// publishes a top-down, north-up contour `Path` traced in a fixed
/// `traceSize` square. Sparse fetches, like the street map. Shared singleton so
/// the PiP frame renderer can draw the same contours.
@MainActor
final class ElevationModel: ObservableObject {
    static let shared = ElevationModel()
    /// Side of the square the contours are traced into (points); the renderer
    /// scales this to the screen.
    static let traceSize: CGFloat = 240

    @Published private(set) var contourPath: Path?

    private var center: CLLocationCoordinate2D?
    private var lastFetch = Date.distantPast
    private var inFlight = false
    private let gridN = 10            // 10×10 = 100 points — one Open-Meteo call
    private let spanMeters = 3000.0   // ~3 km square around you

    func update(for coordinate: CLLocationCoordinate2D) {
        guard !inFlight else { return }
        let movedEnough = center.map {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) > 500
        } ?? true
        guard movedEnough,
              Date().timeIntervalSince(lastFetch) > (center == nil ? 20 : 120) else { return }

        inFlight = true
        lastFetch = Date()
        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.inFlight = false } }
            guard let grid = await Self.fetchGrid(around: coordinate,
                                                  n: self.gridN, span: self.spanMeters) else { return }
            let path = Self.buildContours(grid: grid, n: self.gridN)
            await MainActor.run {
                self.center = coordinate
                self.contourPath = path
            }
        }
    }

    /// GET a row-major N×N elevation grid (north-up: row 0 is the northmost).
    private static func fetchGrid(around c: CLLocationCoordinate2D,
                                  n: Int, span: Double) async -> [Double]? {
        let mPerLat = 111_320.0
        let mPerLon = mPerLat * cos(c.latitude * .pi / 180)
        var lats = [String](), lons = [String]()
        for j in 0..<n {
            for i in 0..<n {
                let fx = Double(i) / Double(n - 1) - 0.5   // west→east
                let fy = Double(j) / Double(n - 1) - 0.5   // north→south (row 0 = north)
                let lat = c.latitude - fy * span / mPerLat
                let lon = c.longitude + fx * span / mPerLon
                lats.append(String(format: "%.5f", lat))
                lons.append(String(format: "%.5f", lon))
            }
        }
        var comp = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        comp.queryItems = [
            URLQueryItem(name: "latitude", value: lats.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: lons.joined(separator: ",")),
        ]
        guard let url = comp.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("YouAreHere/1.0 (iOS wayfinding app)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ElevationResponse.self, from: data),
              decoded.elevation.count == n * n else { return nil }
        return decoded.elevation
    }

    /// Marching squares over a bilinear interpolation of the fetched grid, at
    /// ~8 evenly spaced ISO levels between the grid's min and max elevation.
    /// Flat areas (little relief) trace nothing — by design.
    private static func buildContours(grid: [Double], n: Int) -> Path {
        guard grid.count == n * n, let minE = grid.min(), let maxE = grid.max(),
              maxE - minE > 3 else { return Path() }   // < 3 m relief: too flat
        let ts = Double(traceSize)
        func sample(_ x: Double, _ y: Double) -> Double {
            let gx = min(Double(n - 1), max(0, x / ts * Double(n - 1)))
            let gy = min(Double(n - 1), max(0, y / ts * Double(n - 1)))
            let x0 = Int(gx), y0 = Int(gy)
            let x1 = min(n - 1, x0 + 1), y1 = min(n - 1, y0 + 1)
            let fx = gx - Double(x0), fy = gy - Double(y0)
            let a = grid[y0 * n + x0], b = grid[y0 * n + x1]
            let c = grid[y1 * n + x0], d = grid[y1 * n + x1]
            return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
        }
        let levels = (1...8).map { minE + (maxE - minE) * Double($0) / 9.0 }
        return ContourTracer.path(width: traceSize, height: traceSize, cell: 4,
                                  levels: levels, sample: sample)
    }

    private struct ElevationResponse: Decodable { let elevation: [Double] }
}

/// Real topographic contours around you, drawn 2-D top-down (north-up).
struct TopoBackground: View {
    @EnvironmentObject private var engine: LocationEngine
    @ObservedObject private var model = ElevationModel.shared
    @AppStorage(SettingsKey.backgroundContrast) private var contrast = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            Canvas { ctx, size in
                if let path = model.contourPath {
                    BackgroundArtRenderer.drawTopoContours(
                        &ctx, size: size, path: path,
                        traceSize: ElevationModel.traceSize,
                        date: timeline.date, contrast: contrast)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onReceive(engine.$lastCoordinate.compactMap { $0 }) { coordinate in
            model.update(for: coordinate)
        }
    }
}

// MARK: - Procedural (on-device fractal-noise contours)

/// Reference-type cache mutated inside the Canvas draw closure: the path is
/// built lazily on the first draw with the canvas's *actual* size, which
/// sidesteps GeometryReader first-layout races entirely.
private final class TopoCache {
    var size = CGSize.zero
    var path = Path()
}

struct ProceduralBackground: View {
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

// MARK: - Slope (altitude sparkline of the drive so far)

/// Plots the engine's recorded trail: current altitude on the right edge with a
/// big dot, earlier terrain trailing off to the left. `selected` (from
/// ContentView's pan gesture) moves the playhead into the past; nil tracks the
/// live "now". Redraws on a slow timeline so the live trace keeps advancing.
/// Remembers the last axis extremes (and when they last changed) across redraws,
/// so the label for a just-changed min/max can flash. A reference type mutated
/// inside the Canvas closure — the ProceduralBackground cache pattern.
private final class SlopeAxisState {
    var lastMin: Double?
    var lastMax: Double?
    var minFlashUntil = Date.distantPast
    var maxFlashUntil = Date.distantPast
}

struct SlopeBackground: View {
    @EnvironmentObject private var engine: LocationEngine
    @AppStorage(SettingsKey.backgroundContrast) private var contrast = 1.0
    /// The trail to draw (live recording, or a saved route in playback).
    var track: TrackLog
    /// nil = live (playhead follows the active clock, which freezes itself
    /// while parked); a value = scrubbed into the past.
    var selected: TimeInterval?
    @State private var axis = SlopeAxisState()

    /// How long a min/max label stays flashed after the graph rescales.
    private let flashDuration: TimeInterval = 1.2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            Canvas { ctx, size in
                let samples = track.samples
                let now = timeline.date

                // Flash the label whose extreme just changed (the graph rescaled).
                let alts = samples.compactMap { $0.altitudeMeters }
                if let lo = alts.min(), let hi = alts.max() {
                    if let last = axis.lastMin, lo != last { axis.minFlashUntil = now.addingTimeInterval(flashDuration) }
                    if let last = axis.lastMax, hi != last { axis.maxFlashUntil = now.addingTimeInterval(flashDuration) }
                    axis.lastMin = lo
                    axis.lastMax = hi
                }

                BackgroundArtRenderer.drawSlope(
                    &ctx, size: size,
                    samples: samples,
                    playhead: selected ?? track.activeDuration,
                    pauseMarks: track.pauseMarks,
                    minLabelFlash: now < axis.minFlashUntil,
                    maxLabelFlash: now < axis.maxFlashUntil,
                    metric: engine.state.unitIsMetric,
                    family: engine.state.appFont,
                    contrast: contrast)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Route (2-D trace of the drive so far)

/// Draws the engine's trail as a route map — the path auto-fit to the view with
/// a dot at the playhead. `selected` (from ContentView's pan gesture) moves the
/// dot back along the path; `zoom` (from the pinch gesture) magnifies toward it.
/// nil `selected` tracks live "now".
struct RouteBackground: View {
    @AppStorage(SettingsKey.backgroundContrast) private var contrast = 1.0
    /// The trail to draw (live recording, or a saved route in playback).
    var track: TrackLog
    /// Playhead on the active-time axis; nil = live.
    var selected: TimeInterval?
    var zoom: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Canvas { ctx, size in
                BackgroundArtRenderer.drawRoute(
                    &ctx, size: size,
                    samples: track.samples,
                    playhead: selected ?? track.activeDuration,
                    zoom: zoom,
                    contrast: contrast)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// Procedural has no data dependency, so it's the previewable one; real Topo
// needs a fetch + the engine's coordinate.
#Preview("Procedural") {
    ZStack {
        Theme.background.ignoresSafeArea()
        ProceduralBackground()
    }
}
