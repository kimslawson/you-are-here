import SwiftUI
import Combine
import CoreLocation

/// Purely-aesthetic background layers (Settings ▸ Appearance ▸ Background).
/// Inspired by idle car-nav displays: barely-there, deliberately too abstract
/// to navigate by, and slow enough that nothing pulls the eye.
enum BackgroundArt: String, CaseIterable, Identifiable {
    case off
    /// A perspective-tilted, slowly rotating sketch of nearby roads (OSM).
    case streets
    /// Slowly drifting topographic contour lines, generated on-device.
    case topo

    var id: String { rawValue }
}

/// Switchboard the app screen embeds behind the readout.
struct BackgroundArtView: View {
    let kind: BackgroundArt

    var body: some View {
        switch kind {
        case .off:     EmptyView()
        case .streets: StreetsBackground()
        case .topo:    TopoBackground()
        }
    }
}

// MARK: - Streets (Overpass geometry, tilted like an idle nav display)

/// Fetches nearby road geometry from Overpass, sparsely: once on the first
/// fix, then only after moving ~400m, never more often than every 2 minutes.
/// Polylines are stored in meters relative to the fetch center.
@MainActor
final class StreetMapModel: ObservableObject {
    struct Road {
        let points: [CGPoint]   // meters east/north of center
        let major: Bool         // motorway/trunk/primary get a brighter stroke
    }

    @Published private(set) var roads: [Road] = []

    private var center: CLLocationCoordinate2D?
    private var lastFetch = Date.distantPast
    private var inFlight = false
    private let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    func update(for coordinate: CLLocationCoordinate2D) {
        guard !inFlight else { return }
        let movedEnough = center.map {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) > 400
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
                              endpoint: URL) async -> [Road]? {
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let query = """
        [out:json][timeout:10];way(around:1000,\(lat),\(lon))[highway]\
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
            return Road(points: pts, major: major)
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
/// from the viewer, rotating imperceptibly (one full turn every 25 minutes),
/// fading out toward the horizon.
struct StreetsBackground: View {
    @EnvironmentObject private var engine: LocationEngine
    @StateObject private var model = StreetMapModel()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let drift = Angle.degrees(t * 360 / 1500)   // 25 min per turn
                let scale = min(size.width, size.height) / 1600   // 1km radius ≈ 62% of min side

                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                ctx.rotate(by: drift)

                var minor = Path(), major = Path()
                for road in model.roads {
                    var p = Path()
                    p.addLines(road.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
                    if road.major { major.addPath(p) } else { minor.addPath(p) }
                }
                ctx.stroke(minor, with: .color(Theme.secondary.opacity(0.07)), lineWidth: 1)
                ctx.stroke(major, with: .color(Theme.secondary.opacity(0.13)), lineWidth: 1.5)
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

// MARK: - Topo (procedural contour lines, no data source at all)

/// Slowly drifting contour lines over on-device value noise — the *look* of a
/// topographic map with no relationship to real terrain, which is the point.
struct TopoBackground: View {
    @State private var contours = Path()
    @State private var builtSize: CGSize = .zero
    /// Extra canvas beyond the screen so the drift never exposes an edge.
    private let margin: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Canvas { ctx, _ in
                    // Lissajous drift, ±32pt over ~10/13-minute periods:
                    // technically always moving, practically imperceptible.
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    ctx.translateBy(x: -margin + sin(t / 97) * 32,
                                    y: -margin + cos(t / 131) * 32)
                    ctx.stroke(contours, with: .color(Theme.secondary.opacity(0.09)), lineWidth: 1)
                }
            }
            .onAppear { rebuildIfNeeded(for: geo.size) }
            .onChange(of: geo.size) { rebuildIfNeeded(for: $0) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func rebuildIfNeeded(for size: CGSize) {
        guard size != builtSize, size.width > 0, size.height > 0 else { return }
        builtSize = size
        contours = TopoField().contours(
            size: CGSize(width: size.width + margin * 2 + 64,
                         height: size.height + margin * 2 + 64))
    }
}

/// Fractal value noise + marching squares = contour lines.
struct TopoField {
    var seed: UInt64 = 0x5EED_1A7E

    /// Deterministic lattice hash in [0, 1).
    private func lattice(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F
        h ^= seed
        h = (h ^ (h >> 31)) &* 0xD6E8FEB86659FD93
        h ^= h >> 32
        return Double(h & 0xFFFFFF) / Double(0x1000000)
    }

    private func valueNoise(_ x: Double, _ y: Double) -> Double {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        // Smoothstep, so contours come out rounded rather than faceted.
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = lattice(x0, y0), b = lattice(x0 + 1, y0)
        let c = lattice(x0, y0 + 1), d = lattice(x0 + 1, y0 + 1)
        return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
    }

    /// 4-octave fBm; base wavelength ~240pt reads as unhurried terrain.
    private func height(_ x: Double, _ y: Double) -> Double {
        var value = 0.0, amplitude = 0.5, frequency = 1.0 / 240
        for _ in 0..<4 {
            value += amplitude * valueNoise(x * frequency, y * frequency)
            amplitude *= 0.5
            frequency *= 2
        }
        return value
    }

    /// Marching squares over a coarse grid, several ISO levels.
    func contours(size: CGSize, cell: CGFloat = 8) -> Path {
        let cols = Int(size.width / cell) + 1
        let rows = Int(size.height / cell) + 1
        // Sample once; ~ (cols+1)(rows+1) height() calls.
        var field = [Double](repeating: 0, count: (cols + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...cols {
                field[j * (cols + 1) + i] = height(Double(i) * cell, Double(j) * cell)
            }
        }

        var path = Path()
        for level in stride(from: 0.32, through: 0.68, by: 0.06) {
            for j in 0..<rows {
                for i in 0..<cols {
                    let tl = field[j * (cols + 1) + i]
                    let tr = field[j * (cols + 1) + i + 1]
                    let bl = field[(j + 1) * (cols + 1) + i]
                    let br = field[(j + 1) * (cols + 1) + i + 1]
                    let x = CGFloat(i) * cell, y = CGFloat(j) * cell

                    // Interpolated crossing point on each cell edge.
                    func lerp(_ a: Double, _ b: Double) -> CGFloat {
                        CGFloat((level - a) / (b - a))
                    }
                    let top = CGPoint(x: x + lerp(tl, tr) * cell, y: y)
                    let bottom = CGPoint(x: x + lerp(bl, br) * cell, y: y + cell)
                    let left = CGPoint(x: x, y: y + lerp(tl, bl) * cell)
                    let right = CGPoint(x: x + cell, y: y + lerp(tr, br) * cell)

                    var index = 0
                    if tl > level { index |= 8 }
                    if tr > level { index |= 4 }
                    if br > level { index |= 2 }
                    if bl > level { index |= 1 }

                    func segment(_ a: CGPoint, _ b: CGPoint) {
                        path.move(to: a); path.addLine(to: b)
                    }
                    switch index {
                    case 1, 14:  segment(left, bottom)
                    case 2, 13:  segment(bottom, right)
                    case 3, 12:  segment(left, right)
                    case 4, 11:  segment(top, right)
                    case 5:      segment(left, top); segment(bottom, right)
                    case 6, 9:   segment(top, bottom)
                    case 7, 8:   segment(left, top)
                    case 10:     segment(top, right); segment(left, bottom)
                    default:     break   // 0, 15: no crossing
                    }
                }
            }
        }
        return path
    }
}

#Preview("Topo") {
    ZStack {
        Theme.background.ignoresSafeArea()
        TopoBackground()
    }
}
