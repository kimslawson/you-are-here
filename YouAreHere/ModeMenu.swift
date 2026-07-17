import SwiftUI

/// The HUD's mode picker: a vertical menu anchored above the control bezel,
/// one row per mode with a live-rendered preview swatch, the mode's name, and
/// a check on the current one. A plain list (not a radial menu) on purpose —
/// it stays legible and fat-targeted at seven-plus modes and grows by one row
/// per future mode instead of shrinking every wedge.
struct ModeMenuView: View {
    let track: TrackLog
    let current: BackgroundArt
    let onSelect: (BackgroundArt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(BackgroundArt.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    HStack(spacing: 12) {
                        ModeSwatch(mode: mode, track: track)
                            .frame(width: 56, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
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
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 250)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A miniature live render of one mode, using the real renderers and the real
/// session data (roads, contours, the trail). Drawn at a virtual 200×128 and
/// scaled down, so line weights and labels shrink with it instead of
/// swallowing the swatch. Static (one-shot) — it's a menu, not a window.
struct ModeSwatch: View {
    @EnvironmentObject private var engine: LocationEngine
    let mode: BackgroundArt
    let track: TrackLog

    /// Punchier than the live backdrop so a 56pt swatch still reads.
    private let contrast = 1.6
    private static let virtualSize = CGSize(width: 200, height: 128)

    var body: some View {
        ZStack {
            // Neon previews on black even in light mode (it's dark-only).
            mode == .neon ? Color.black : Theme.background
            Canvas { ctx, size in
                switch mode {
                case .off:
                    break
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
                        samples: track.samples, playhead: track.activeDuration,
                        pauseMarks: track.pauseMarks,
                        metric: engine.state.unitIsMetric,
                        family: engine.state.appFont,
                        contrast: contrast)
                case .route:
                    BackgroundArtRenderer.drawRoute(
                        &ctx, size: size,
                        samples: track.samples, playhead: track.activeDuration,
                        zoom: 1, contrast: contrast)
                }
            }
            .frame(width: Self.virtualSize.width, height: Self.virtualSize.height)
            .scaleEffect(56 / Self.virtualSize.width)
            if mode == .off {
                Image(systemName: "circle.slash")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.muted)
            }
        }
    }
}
