import SwiftUI

/// Purely-aesthetic background layers (Settings ▸ Appearance ▸ Background).
/// Inspired by idle car-nav displays: dim, deliberately too abstract to
/// navigate by, and slow enough that nothing pulls the eye.
enum BackgroundArt: String, CaseIterable, Identifiable {
    case off
    /// A perspective-tilted, slowly rotating sketch of nearby roads (OSM).
    /// App + PiP only: road geometry can't ride in the Live Activity's state
    /// (ActivityKit budgets content to ~4KB) and widgets can't fetch.
    case streets
    /// Real topographic contours around you, from fetched elevation data
    /// (Open-Meteo), drawn 2-D top-down. App + PiP only (needs the fetch).
    case topo
    /// On-device fractal-noise contours — the offline/flat-terrain fallback for
    /// `topo`. Self-contained, so it renders on every surface.
    case procedural
    /// Dim synthwave grid whose scroll speed follows GPS speed (in the app;
    /// elsewhere it rolls at a steady idle). Dark mode only.
    case neon
    /// An altitude sparkline of the drive so far, the current altitude on the
    /// right edge trailing off to the left. App + PiP only (the trail lives in
    /// the app process): the app lets you swipe it back through the trip to
    /// retrace the readout; the floating window shows it live, un-scrubbed.
    case slope
    /// A 2-D trace of the route driven so far, auto-fit to the view with a dot
    /// at your position. App + PiP only (same trail as Slope): the app lets you
    /// swipe the dot back along the path (retracing the readout) and pinch to
    /// zoom; the floating window shows it live, un-scrubbed, fit-to-view.
    case route

    var id: String { rawValue }
}

/// One road polyline, in meters east/north of the fetch center.
struct RoadStroke {
    let points: [CGPoint]
    let major: Bool   // motorway/trunk/primary get a brighter stroke
}

/// Pure drawing for the three effects, shared by the app screen (animated),
/// the PiP frames (~1 fps), and the Live Activity (static per update).
/// All state comes in as parameters; nothing here fetches or animates.
enum BackgroundArtRenderer {

    // MARK: Topo

    /// Canvas padding beyond the visible size so the drift never shows an edge.
    static let topoMargin: CGFloat = 44

    /// Contour lines over fractal value noise (marching squares). Pure and
    /// deterministic per size — cacheable by the caller, cheap enough to
    /// recompute per render for small canvases (PiP, Live Activity).
    static func topoContours(size: CGSize) -> Path {
        TopoField().contours(size: CGSize(width: size.width + topoMargin * 2 + 64,
                                          height: size.height + topoMargin * 2 + 64))
    }

    static func drawTopo(_ ctx: inout GraphicsContext, size: CGSize, path: Path, date: Date,
                         contrast: Double = 1) {
        // Lissajous drift, ±32pt over ~10/13-minute periods: technically
        // always moving, practically imperceptible.
        let t = date.timeIntervalSinceReferenceDate
        ctx.translateBy(x: -topoMargin + sin(t / 97) * 32,
                        y: -topoMargin + cos(t / 131) * 32)
        ctx.stroke(path, with: .color(Theme.secondary.opacity(min(1, 0.30 * contrast))), lineWidth: 1.2)
    }

    /// Draw a pre-traced *real* elevation contour path (built in a `traceSize`
    /// square, north-up) top-down: scaled to overfill the canvas, centered, with
    /// the same gentle drift and line spec as the procedural topo. The line
    /// width is divided by the scale so it lands ~1.2pt on screen.
    static func drawTopoContours(_ ctx: inout GraphicsContext, size: CGSize, path: Path,
                                 traceSize: CGFloat, date: Date, contrast: Double) {
        let scale = max(size.width, size.height) / traceSize * 1.15
        let t = date.timeIntervalSinceReferenceDate
        ctx.translateBy(x: size.width / 2 + sin(t / 97) * 20,
                        y: size.height / 2 + cos(t / 131) * 20)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -traceSize / 2, y: -traceSize / 2)
        ctx.stroke(path, with: .color(Theme.secondary.opacity(min(1, 0.30 * contrast))),
                   lineWidth: 1.2 / scale)
    }

    // MARK: Streets

    /// A slow turntable for contexts without their own drift state: one full
    /// rotation every 25 minutes.
    static func streetsAutoAngle(at date: Date) -> Angle {
        .degrees(date.timeIntervalSinceReferenceDate * 360 / 1500)
    }

    static func drawStreets(_ ctx: inout GraphicsContext, size: CGSize,
                            roads: [RoadStroke], angle: Angle, contrast: Double = 1) {
        let scale = min(size.width, size.height) / 1000   // 600m radius overfills the min side
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: angle)

        var minor = Path(), major = Path()
        for road in roads {
            var p = Path()
            p.addLines(road.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
            if road.major { major.addPath(p) } else { minor.addPath(p) }
        }
        ctx.stroke(minor, with: .color(Theme.secondary.opacity(min(1, 0.25 * contrast))), lineWidth: 1.2)
        ctx.stroke(major, with: .color(Theme.secondary.opacity(min(1, 0.40 * contrast))), lineWidth: 1.8)
    }

    // MARK: Neon

    /// Steady scroll for contexts that can't integrate speed (PiP frames,
    /// Live Activity renders): the idle-crawl rate.
    static func neonAutoPhase(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate * 0.25).truncatingRemainder(dividingBy: 1)
    }

    static func drawNeon(_ ctx: inout GraphicsContext, size: CGSize, phase: Double,
                         contrast: Double = 1) {
        let w = size.width, h = size.height
        let horizonY = h * 0.42
        let gridHeight = h - horizonY
        let magenta = Color(red: 1.0, green: 0.25, blue: 0.75)
        let cyan = Color(red: 0.3, green: 0.9, blue: 1.0)
        let portrait = h > w

        // Sun: gradient disc with widening scanline gaps, on the horizon.
        let sunRadius = min(w, h) * 0.17
        let sunCenter = CGPoint(x: w * 0.5, y: horizonY - sunRadius * 0.35)
        let sun = Path(ellipseIn: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius,
                                         width: sunRadius * 2, height: sunRadius * 2))
        ctx.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: horizonY)))
            layer.fill(sun, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.75, blue: 0.3).opacity(min(1, 0.50 * contrast)),
                                  magenta.opacity(min(1, 0.32 * contrast))]),
                startPoint: CGPoint(x: sunCenter.x, y: sunCenter.y - sunRadius),
                endPoint: CGPoint(x: sunCenter.x, y: sunCenter.y + sunRadius)))
            // Cut lines: start at the equator, thickness and gap growing
            // together toward the bottom for the classic round outrun falloff.
            // More, thinner stripes than a fixed step gives the rounder feel.
            layer.blendMode = .clear
            var stripeY = sunCenter.y + sunRadius * 0.03
            var thickness = sunRadius * 0.02
            var gap = sunRadius * 0.04
            while stripeY < sunCenter.y + sunRadius {
                layer.fill(Path(CGRect(x: sunCenter.x - sunRadius, y: stripeY,
                                       width: sunRadius * 2, height: thickness)),
                           with: .color(.black))
                stripeY += thickness + gap
                thickness *= 1.2
                gap *= 1.2
            }
        }

        // Cyan procedural city skyline sitting on the horizon (stable frame to
        // frame — deterministic per building index).
        drawSkyline(&ctx, width: w, horizonY: horizonY, unit: min(w, h),
                    color: cyan, contrast: contrast)

        // Rows spaced in world depth, projected as 1/depth, sliding toward the
        // viewer as phase rises (seamless: the pattern repeats every `step`, and
        // phase wraps at 1). Portrait doubles the frequency; both run dense
        // enough near the top to meet the skyline instead of leaving a gap.
        let step = portrait ? 0.5 : 1.0
        let horizonGap = max(4, gridHeight * 0.012)
        var n = 1
        while n <= 400 {
            let depth = step * (Double(n) - phase)
            n += 1
            guard depth > 0.05 else { continue }
            let y = horizonY + gridHeight / CGFloat(depth)
            if y > h + 2 { continue }              // still below the screen
            if y < horizonY + horizonGap { break } // reached the horizon
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: w, y: y))
            ctx.stroke(line, with: .color(magenta.opacity(min(1, min(0.45, 0.14 + 0.32 / depth) * contrast))),
                       lineWidth: 1)
        }

        // Verticals: a fan from the vanishing point. Portrait spaces them ~2×
        // wider; the line count is chosen so even the outer ones reach the far
        // left/right a little below the horizon, instead of leaving dark side
        // wedges beside the readout (outer lines just run off the bottom edge).
        var fan = Path()
        let bottomSpacing = (portrait ? 0.2 : 0.1) * w
        let iMax = min(80, max(12, Int((w * 0.5) / (bottomSpacing * 0.10)) + 1))
        for i in -iMax...iMax {
            fan.move(to: CGPoint(x: w * 0.5, y: horizonY))
            fan.addLine(to: CGPoint(x: w * 0.5 + CGFloat(i) * bottomSpacing, y: h))
        }
        ctx.stroke(fan, with: .color(magenta.opacity(min(1, 0.22 * contrast))), lineWidth: 1)
    }

    /// A dim cyan city silhouette on the horizon: filled blocks with brighter
    /// top edges and the occasional antenna. Heights/widths come from a
    /// deterministic hash of the building index, so the skyline is fixed rather
    /// than flickering every frame. A faint baseline grounds it on the horizon.
    private static func drawSkyline(_ ctx: inout GraphicsContext, width: CGFloat,
                                    horizonY: CGFloat, unit: CGFloat,
                                    color: Color, contrast: Double) {
        func rand(_ i: Int, _ salt: Int) -> CGFloat {
            var h = UInt64(bitPattern: Int64(i &* 73856093 ^ salt &* 19349663))
            h = (h ^ (h >> 33)) &* 0xff51afd7ed558ccd
            h ^= h >> 33
            return CGFloat(h & 0xFFFF) / CGFloat(0xFFFF)
        }
        var blocks = Path()
        var tops = Path()
        let maxHeight = unit * 0.14
        var x = -unit * 0.1
        var i = 0
        while x < width + unit * 0.1 {
            let bw = unit * (0.05 + rand(i, 1) * 0.06)
            let bh = maxHeight * (0.22 + rand(i, 2) * 0.78)
            let rect = CGRect(x: x, y: horizonY - bh, width: bw * 0.9, height: bh)
            blocks.addRect(rect)
            tops.move(to: CGPoint(x: rect.minX, y: rect.minY))
            tops.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            if rand(i, 3) > 0.82 {   // occasional antenna
                tops.move(to: CGPoint(x: rect.midX, y: rect.minY))
                tops.addLine(to: CGPoint(x: rect.midX, y: rect.minY - maxHeight * 0.4))
            }
            x += bw
            i += 1
        }
        ctx.fill(blocks, with: .color(color.opacity(min(1, 0.20 * contrast))))
        ctx.stroke(tops, with: .color(color.opacity(min(1, 0.55 * contrast))), lineWidth: 1)
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: horizonY))
        baseline.addLine(to: CGPoint(x: width, y: horizonY))
        ctx.stroke(baseline, with: .color(color.opacity(min(1, 0.28 * contrast))), lineWidth: 1)
    }

    // MARK: Slope

    /// The screen width spans this many seconds of the drive; older points
    /// scroll off the left (pan to reveal them). Shared with the app's scrub
    /// gesture so dragging N points reveals exactly the time it uncovers.
    static let slopeWindowSeconds: Double = 360

    static func slopePointsPerSecond(width: CGFloat) -> CGFloat {
        width / CGFloat(slopeWindowSeconds)
    }

    /// An altitude sparkline of the drive so far. The right edge is a "playhead":
    /// the sample at `playhead` sits there with a big dot on its altitude, and
    /// earlier samples trail left, off-screen. The altitude axis auto-fits the
    /// session's real min/max; faint gridline ticks and the min/max labels stay
    /// pinned to the left while the trace pans behind them. Panning the playhead
    /// into the past is the app's job — it hands us the chosen `playhead`; here
    /// we only draw.
    static func drawSlope(_ ctx: inout GraphicsContext, size: CGSize,
                          samples: [TrackSample], playhead: Date,
                          pausePoints: [Date] = [],
                          minLabelFlash: Bool = false, maxLabelFlash: Bool = false,
                          metric: Bool, family: AppFont, contrast: Double) {
        let w = size.width, h = size.height
        // The dot sits just inside the right edge so it isn't clipped in half.
        let inset = max(6, min(w, h) * 0.05)
        let anchorX = w - inset

        let alts = samples.compactMap { $0.altitudeMeters }
        guard samples.count >= 2, let lo = alts.min(), let hi = alts.max() else { return }

        // Altitude band: the max line and min line pass through the real extremes
        // (so the labels always match them). Centered and sized off the short
        // side, so it fills a wide (landscape) view but stays gently un-stretched
        // and well inset in a tall (portrait) one — clearing the rounded corners
        // and the notch either way.
        let band = min(w, h) * 0.70
        let maxLineY = (h - band) / 2
        let minLineY = (h + band) / 2
        func y(_ meters: Double) -> CGFloat {
            guard hi > lo else { return (maxLineY + minLineY) / 2 }
            let f = (meters - lo) / (hi - lo)          // 0 at min, 1 at max
            return minLineY - CGFloat(f) * (minLineY - maxLineY)
        }
        let pps = slopePointsPerSecond(width: w)

        // The two reference lines through the extremes (screen-pinned; the trace
        // pans behind them).
        var grid = Path()
        for ly in [maxLineY, minLineY] {
            grid.move(to: CGPoint(x: 0, y: ly))
            grid.addLine(to: CGPoint(x: w, y: ly))
        }
        ctx.stroke(grid, with: .color(Theme.secondary.opacity(min(1, 0.18 * contrast))), lineWidth: 1)

        // Sea level: once the trace has dipped below zero, keep a thin dashed
        // line pinned at altitude 0 (it rides the y-mapping as the range rescales).
        if lo < 0 {
            let zeroY = y(0)
            if zeroY >= 0, zeroY <= h {
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: zeroY))
                zero.addLine(to: CGPoint(x: w, y: zeroY))
                ctx.stroke(zero, with: .color(Theme.secondary.opacity(min(1, 0.3 * contrast))),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }

        // Min / max labels, sitting just outside their lines and inset from the
        // left edge so the rounded corner doesn't clip them. A label flashes (in
        // the flash color) on the frames right after its value changed — i.e. the
        // graph just rescaled around a new extreme.
        let dimLabel = Theme.secondary.opacity(min(1, 0.5 * contrast))
        let flashLabel = Theme.flash.opacity(min(1, 0.9 * contrast))
        let labelSize = max(9, min(w, h) * 0.03)
        let labelFont = Theme.font(size: labelSize, weight: .medium, family: family)
        let labelX = max(12, min(w, h) * 0.045)
        func label(_ meters: Double, at gy: CGFloat, color: Color) {
            ctx.draw(Text(Formatting.altitudeString(meters: meters, metric: metric))
                        .font(labelFont).foregroundColor(color),
                     at: CGPoint(x: labelX, y: gy), anchor: .leading)
        }
        label(hi, at: maxLineY - labelSize * 0.8, color: maxLabelFlash ? flashLabel : dimLabel)
        label(lo, at: minLineY + labelSize * 0.8, color: minLabelFlash ? flashLabel : dimLabel)

        // Pause markers: a subtle dashed vertical line at each park on the trail.
        for pause in pausePoints {
            let px = anchorX - CGFloat(playhead.timeIntervalSince(pause)) * pps
            guard px >= 0, px <= w else { continue }
            var mark = Path()
            mark.move(to: CGPoint(x: px, y: 0))
            mark.addLine(to: CGPoint(x: px, y: h))
            ctx.stroke(mark, with: .color(Theme.secondary.opacity(min(1, 0.28 * contrast))),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }

        // The trace, up to the playhead. Only near-visible points join the path
        // (everything older is off the left edge anyway).
        let leftCutoff = playhead.addingTimeInterval(-Double((anchorX + 24) / pps))
        var line = Path()
        var started = false
        for s in samples {
            if s.date < leftCutoff { continue }
            if s.date > playhead { break }        // samples are time-sorted
            guard let a = s.altitudeMeters else { continue }
            let p = CGPoint(x: anchorX - CGFloat(playhead.timeIntervalSince(s.date)) * pps, y: y(a))
            if started { line.addLine(to: p) } else { line.move(to: p); started = true }
        }

        // The trace and dot draw in the flash color (the trail is the "live"
        // element here); gridlines and labels stay dim.
        let traceColor = Theme.flash.opacity(min(1, 0.55 * contrast))
        guard let headAlt = slopeAltitude(at: playhead, samples: samples) else {
            ctx.stroke(line, with: .color(traceColor), lineWidth: 1.6)
            return
        }
        // Connect the trace to the playhead dot, then draw the dot on the
        // current altitude.
        let dot = CGPoint(x: anchorX, y: y(headAlt))
        if started { line.addLine(to: dot) } else { line.move(to: dot) }
        ctx.stroke(line, with: .color(traceColor), lineWidth: 1.6)

        let r = max(3, min(w, h) * 0.02)
        ctx.fill(Path(ellipseIn: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)),
                 with: .color(Theme.flash.opacity(min(1, 0.85 * contrast))))
    }

    /// The recorded altitude at or before `date` (last non-nil), for the dot.
    private static func slopeAltitude(at date: Date, samples: [TrackSample]) -> Double? {
        for s in samples.reversed() where s.date <= date {
            if let a = s.altitudeMeters { return a }
        }
        return nil
    }

    // MARK: Route

    /// Zoom `1` fits the whole route; the app clamps its pinch to this floor so
    /// you can't zoom out past the full extent.
    static let routeMinZoom: CGFloat = 1
    static let routeMaxZoom: CGFloat = 20

    /// A 2-D trace of the route driven so far, in the flash color, with a dot at
    /// the `playhead` position. The whole route auto-fits the view at `zoom` 1;
    /// pinching in (zoom > 1) magnifies toward the dot. Panning the playhead
    /// along the path is the app's job — it hands us `playhead`; here we draw.
    static func drawRoute(_ ctx: inout GraphicsContext, size: CGSize,
                          samples: [TrackSample], playhead: Date,
                          zoom: CGFloat, contrast: Double) {
        let w = size.width, h = size.height
        let located = samples.filter { $0.latitude != nil && $0.longitude != nil }
        guard !located.isEmpty else { return }

        // Equirectangular projection around the route's mean coordinate (plenty
        // accurate over a drive); north is up. y grows downward on screen, so
        // negate latitude.
        let n = Double(located.count)
        let lat0 = located.reduce(0.0) { $0 + $1.latitude! } / n
        let lon0 = located.reduce(0.0) { $0 + $1.longitude! } / n
        let mPerLat = 111_320.0
        let mPerLon = mPerLat * cos(lat0 * .pi / 180)
        func project(_ s: TrackSample) -> CGPoint {
            CGPoint(x: CGFloat((s.longitude! - lon0) * mPerLon),
                    y: CGFloat(-(s.latitude! - lat0) * mPerLat))
        }
        let pts = located.map(project)

        // Bounding box of the whole route → the fit scale (zoom 1 shows it all).
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let bboxW = max(maxX - minX, 1), bboxH = max(maxY - minY, 1)
        let bboxCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        // Fit with a margin; cap so a tiny (parked) route doesn't blow up to
        // fill the screen with GPS jitter — keep at least ~40 m visible.
        let minSide = min(w, h)
        let fitScale = min((w * 0.86) / bboxW, (h * 0.86) / bboxH, minSide / 40)
        let scale = fitScale * max(routeMinZoom, zoom)

        // Focus: the bbox center when fully zoomed out (so the whole route stays
        // on screen), easing to the dot as you pinch in (so it follows you).
        let head = routeHead(playhead: playhead, located: located, project: project) ?? bboxCenter
        let follow = min(1, max(0, (zoom - 1) / 0.5))
        let focus = CGPoint(x: bboxCenter.x + (head.x - bboxCenter.x) * follow,
                            y: bboxCenter.y + (head.y - bboxCenter.y) * follow)
        func screen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: w / 2 + (p.x - focus.x) * scale, y: h / 2 + (p.y - focus.y) * scale)
        }

        let color = Theme.flash
        let stroke = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        if pts.count >= 2 {
            // Split at the playhead: the part already driven at full intensity,
            // the not-yet-reached part (only visible when scrubbing back) at half.
            var traveled = Path(), ahead = Path()
            var lastTraveled: CGPoint?
            var aheadStarted = false
            for (i, p) in pts.enumerated() {
                let sp = screen(p)
                if located[i].date <= playhead {
                    if traveled.isEmpty { traveled.move(to: sp) } else { traveled.addLine(to: sp) }
                    lastTraveled = sp
                } else if !aheadStarted {
                    // Bridge from the last driven point so the two halves meet.
                    if let l = lastTraveled { ahead.move(to: l); ahead.addLine(to: sp) }
                    else { ahead.move(to: sp) }
                    aheadStarted = true
                } else {
                    ahead.addLine(to: sp)
                }
            }
            ctx.stroke(ahead, with: .color(color.opacity(min(1, 0.275 * contrast))), style: stroke)
            ctx.stroke(traveled, with: .color(color.opacity(min(1, 0.55 * contrast))), style: stroke)
        }

        // The "you are here" dot at the playhead.
        let d = screen(head)
        let r = max(3.5, minSide * 0.022)
        ctx.fill(Path(ellipseIn: CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)),
                 with: .color(color.opacity(min(1, 0.9 * contrast))))
    }

    /// The projected route point at or before `playhead` (the last located
    /// sample not after it), for the dot.
    private static func routeHead(playhead: Date, located: [TrackSample],
                                  project: (TrackSample) -> CGPoint) -> CGPoint? {
        var chosen: TrackSample?
        for s in located where s.date <= playhead { chosen = s }
        return (chosen ?? located.first).map(project)
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

    /// Procedural contours: marching squares over the fBm height field.
    func contours(size: CGSize, cell: CGFloat = 8) -> Path {
        ContourTracer.path(width: size.width, height: size.height, cell: cell,
                           levels: Array(stride(from: 0.32, through: 0.68, by: 0.06)),
                           sample: { self.height($0, $1) })
    }
}

/// Marching squares over an arbitrary sampled height field — shared by the
/// procedural topo (fBm sample) and the real topo (bilinear over fetched
/// elevation). Traces one polyline segment per crossing at each ISO level.
enum ContourTracer {
    static func path(width: CGFloat, height: CGFloat, cell: CGFloat,
                     levels: [Double], sample: (Double, Double) -> Double) -> Path {
        let cols = Int(width / cell) + 1
        let rows = Int(height / cell) + 1
        var field = [Double](repeating: 0, count: (cols + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...cols {
                field[j * (cols + 1) + i] = sample(Double(i) * Double(cell), Double(j) * Double(cell))
            }
        }

        var path = Path()
        for level in levels {
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
