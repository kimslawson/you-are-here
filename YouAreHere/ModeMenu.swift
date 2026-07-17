import SwiftUI
import UIKit

/// The HUD's mode picker: a vertical menu anchored above the control bezel,
/// one row per mode with a square preview swatch filling the cell's height,
/// the mode's name, and a check on the current one. A plain list (not a radial
/// menu) on purpose — it stays legible and fat-targeted at seven-plus modes
/// and grows by one row per future mode instead of shrinking every wedge.
struct ModeMenuView: View {
    @EnvironmentObject private var engine: LocationEngine
    let track: TrackLog
    let current: BackgroundArt
    /// Cap so the menu never outgrows the screen (landscape); it scrolls past this.
    var maxHeight: CGFloat = .infinity
    let onSelect: (BackgroundArt) -> Void

    @State private var swatches: [BackgroundArt: UIImage] = [:]

    private static let rowHeight: CGFloat = 60
    private static let rowSpacing: CGFloat = 2

    var body: some View {
        let modes = BackgroundArt.allCases
        let contentHeight = CGFloat(modes.count) * Self.rowHeight
            + CGFloat(modes.count - 1) * Self.rowSpacing + 16
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(modes) { mode in
                    Button {
                        onSelect(mode)
                    } label: {
                        HStack(spacing: 12) {
                            // Square, filling the cell top-to-bottom.
                            swatch(for: mode)
                                .frame(width: Self.rowHeight, height: Self.rowHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.secondary.opacity(0.35), lineWidth: 1))
                            Text(mode.label)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(Theme.primary)
                            Spacer(minLength: 12)
                            if mode == current {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.primary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 260, height: min(contentHeight, maxHeight))
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            swatches = ModeSwatchCache.shared.refresh(
                track: track,
                metric: engine.state.unitIsMetric,
                family: engine.state.appFont,
                light: engine.state.lightMode)
        }
    }

    @ViewBuilder
    private func swatch(for mode: BackgroundArt) -> some View {
        if mode == .off {
            // Disabled-looking: a dimmed wash with a grey slash corner to corner.
            ZStack {
                Theme.background
                Rectangle().fill(Color.gray.opacity(0.15))
                SlashShape().stroke(Color.gray.opacity(0.55), lineWidth: 2)
            }
        } else if let image = swatches[mode] {
            Image(uiImage: image)
                .resizable()
        } else {
            // Never rendered on this device yet (first run, nothing fetched).
            ZStack {
                Theme.background
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.muted)
            }
        }
    }
}

/// A "/" corner to corner, for the Off tile's slash.
private struct SlashShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// Renders and remembers mode swatches. A mode with live session data (roads
/// fetched, contours built, a trail recorded) re-renders fresh and the result
/// is written to disk; a mode without falls back to its last rendering — from
/// earlier this session or a previous one — so the menu shows what each mode
/// actually looks like instead of an honest-but-useless blank. Keyed by
/// light/dark so cached art matches the current palette.
@MainActor
final class ModeSwatchCache {
    static let shared = ModeSwatchCache()

    /// Displayed size (points); rendered at 3× pixels.
    static let side: CGFloat = 60
    /// The renderers draw at this virtual size, scaled down, so line weights
    /// and labels shrink with the swatch instead of swallowing it.
    static let virtualSide: CGFloat = 170

    private var memory: [String: UIImage] = [:]

    private var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ModeSwatches", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func key(_ mode: BackgroundArt, light: Bool) -> String {
        "\(mode.rawValue)-\(light ? "light" : "dark")"
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }

    /// One image per mode (except .off): freshly rendered where the session has
    /// data, cached otherwise. Called when the menu opens — seven small
    /// renders, cheap enough to do on the spot.
    func refresh(track: TrackLog, metric: Bool, family: AppFont,
                 light: Bool) -> [BackgroundArt: UIImage] {
        var result: [BackgroundArt: UIImage] = [:]
        for mode in BackgroundArt.allCases where mode != .off {
            let key = key(mode, light: light)
            if hasLiveData(mode, track: track) {
                let content = SwatchCanvas(mode: mode,
                                           samples: track.samples,
                                           pauseMarks: track.pauseMarks,
                                           playhead: track.activeDuration,
                                           metric: metric, family: family)
                    .frame(width: Self.side, height: Self.side)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 3
                if let image = renderer.uiImage {
                    memory[key] = image
                    try? image.pngData()?.write(to: fileURL(key), options: .atomic)
                    result[mode] = image
                    continue
                }
            }
            if let cached = memory[key] {
                result[mode] = cached
            } else if let data = try? Data(contentsOf: fileURL(key)),
                      let image = UIImage(data: data) {
                memory[key] = image
                result[mode] = image
            }
        }
        return result
    }

    private func hasLiveData(_ mode: BackgroundArt, track: TrackLog) -> Bool {
        switch mode {
        case .off:        return false
        case .streets:    return !StreetMapModel.shared.roads.isEmpty
        case .topo:       return ElevationModel.shared.contourPath != nil
        case .procedural: return true   // self-contained
        case .neon:       return true   // self-contained
        case .slope:      return track.samples.count >= 2
        case .route:
            return track.samples.filter { $0.latitude != nil && $0.longitude != nil }.count >= 2
        }
    }
}

/// The actual miniature render of one mode, using the real renderers and the
/// real session data. Only built for modes that have data (see ModeSwatchCache).
private struct SwatchCanvas: View {
    let mode: BackgroundArt
    let samples: [TrackSample]
    let pauseMarks: [TimeInterval]
    let playhead: TimeInterval
    let metric: Bool
    let family: AppFont

    /// Punchier than the live backdrop so a small swatch still reads.
    private let contrast = 1.6

    var body: some View {
        ZStack {
            // Neon previews on black even in light mode (it's dark-only).
            mode == .neon ? Color.black : Theme.background
            Canvas { ctx, size in
                switch mode {
                case .streets:
                    BackgroundArtRenderer.drawStreets(
                        &ctx, size: size, roads: StreetMapModel.shared.roads,
                        angle: BackgroundArtRenderer.streetsAutoAngle(at: Date()),
                        contrast: contrast)
                case .topo:
                    if let path = ElevationModel.shared.contourPath {
                        BackgroundArtRenderer.drawTopoContours(
                            &ctx, size: size, path: path,
                            traceSize: ElevationModel.traceSize,
                            date: Date(), contrast: contrast)
                    }
                case .procedural:
                    let path = BackgroundArtRenderer.topoContours(size: size)
                    BackgroundArtRenderer.drawTopo(&ctx, size: size, path: path,
                                                   date: Date(), contrast: contrast)
                case .neon:
                    BackgroundArtRenderer.drawNeon(
                        &ctx, size: size,
                        phase: BackgroundArtRenderer.neonAutoPhase(at: Date()),
                        contrast: contrast)
                case .slope:
                    BackgroundArtRenderer.drawSlope(
                        &ctx, size: size,
                        samples: samples, playhead: playhead,
                        pauseMarks: pauseMarks,
                        metric: metric, family: family,
                        contrast: contrast)
                case .route:
                    BackgroundArtRenderer.drawRoute(
                        &ctx, size: size,
                        samples: samples, playhead: playhead,
                        zoom: 1, contrast: contrast)
                case .off:
                    break
                }
            }
            .frame(width: ModeSwatchCache.virtualSide, height: ModeSwatchCache.virtualSide)
            .scaleEffect(ModeSwatchCache.side / ModeSwatchCache.virtualSide)
        }
        .frame(width: ModeSwatchCache.side, height: ModeSwatchCache.side)
        .clipped()
    }
}
