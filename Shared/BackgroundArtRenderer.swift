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
                         heading: Double = 0, contrast: Double = 1) {
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

        // Cyan procedural city skyline sitting on the horizon, panning with the
        // compass heading (deterministic per building index, so it's stable).
        drawSkyline(&ctx, width: w, horizonY: horizonY, unit: min(w, h),
                    color: cyan, contrast: contrast, heading: heading)

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

    /// A cyan city skyline as connected line art that pans with the compass.
    /// The full skyline is a seamless 360° loop; the ~90° FOV means it's 4×
    /// screen-width wide, and heading scrolls a one-screen window through it.
    /// A fixed set of `n` buildings (hashed widths/heights) is scaled to tile
    /// the panorama exactly, and the building index wraps mod n — so the strip
    /// meets itself at north with no seam. See-through (no fill): the sun shows
    /// through it.
    private static func drawSkyline(_ ctx: inout GraphicsContext, width: CGFloat,
                                    horizonY: CGFloat, unit: CGFloat,
                                    color: Color, contrast: Double, heading: Double) {
        func rand(_ i: Int, _ salt: Int) -> CGFloat {
            var h = UInt64(bitPattern: Int64(i &* 73856093 ^ salt &* 19349663))
            h = (h ^ (h >> 33)) &* 0xff51afd7ed558ccd
            h ^= h >> 33
            return CGFloat(h & 0xFFFF) / CGFloat(0xFFFF)
        }
        let n = 48
        let maxHeight = unit * 0.14
        // Base widths + cumulative starts over one period, then scaled so the
        // n buildings tile the 4×-width panorama exactly (seamless wrap).
        var starts = [CGFloat](repeating: 0, count: n)
        var widths = [CGFloat](repeating: 0, count: n)
        var total: CGFloat = 0
        for m in 0..<n {
            starts[m] = total
            widths[m] = unit * (0.05 + rand(m, 1) * 0.06)
            total += widths[m]
        }
        let panoWidth = width * 4          // 90° FOV → 360° is 4 screens
        let scale = panoWidth / total
        let offset = CGFloat(heading / 360) * panoWidth   // pan by heading

        func mod(_ k: Int) -> Int { ((k % n) + n) % n }
        // Continuous position of building k (any integer) across periods.
        func pos(_ k: Int) -> CGFloat {
            CGFloat((k >= 0 ? k / n : (k - n + 1) / n)) * panoWidth + starts[mod(k)] * scale
        }
        func w(_ k: Int) -> CGFloat { widths[mod(k)] * scale }
        func h(_ k: Int) -> CGFloat { maxHeight * (0.22 + rand(mod(k), 2) * 0.78) }

        // First building at or left of the window, then draw across the window.
        var k = Int((offset / panoWidth * CGFloat(n)).rounded(.down)) - 2
        while pos(k + 1) <= offset { k += 1 }
        while pos(k) > offset { k -= 1 }

        var line = Path()
        var antennas = Path()
        line.move(to: CGPoint(x: pos(k) - offset, y: horizonY))
        var guardCount = 0
        while pos(k) - offset < width + w(k), guardCount < 256 {
            let x = pos(k) - offset
            let top = horizonY - h(k)
            let rightX = x + w(k)
            line.addLine(to: CGPoint(x: x, y: top))       // step to this roof
            line.addLine(to: CGPoint(x: rightX, y: top))  // across the roof
            if rand(mod(k), 3) > 0.82 {                    // occasional antenna
                let ax = (x + rightX) / 2
                antennas.move(to: CGPoint(x: ax, y: top))
                antennas.addLine(to: CGPoint(x: ax, y: top - maxHeight * 0.4))
            }
            k += 1
            guardCount += 1
        }
        line.addLine(to: CGPoint(x: pos(k) - offset, y: horizonY))  // down to baseline

        ctx.stroke(line, with: .color(color.opacity(min(1, 0.60 * contrast))), lineWidth: 1.5)
        ctx.stroke(antennas, with: .color(color.opacity(min(1, 0.55 * contrast))), lineWidth: 1)
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: horizonY))
        baseline.addLine(to: CGPoint(x: width, y: horizonY))
        ctx.stroke(baseline, with: .color(color.opacity(min(1, 0.28 * contrast))), lineWidth: 1)
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
