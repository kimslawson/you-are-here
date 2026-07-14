import SwiftUI
import UIKit

/// One prepared share payload. Wrapped for .sheet(item:) — ShareLink wants its
/// items up front, but ours are built on demand from a dialog choice.
struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// The system share sheet (UIActivityViewController) for SwiftUI presentation.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// What "share the current view as an image" renders: the main screen
/// recreated off-screen — backdrop plus readout, honoring any scrub/zoom —
/// rasterized by ImageRenderer at 3×. Mirrors PiPFrameView's backdrop switch;
/// streets/topo reuse the shared fetch models, so the snapshot matches what's
/// on screen.
struct ShareSnapshotView: View {
    let state: LocationActivityAttributes.ContentState
    let displayDate: Date?
    let size: CGSize
    let samples: [TrackSample]
    let pauseMarks: [TimeInterval]
    /// Playhead on the trail's active-time axis (scrubbed or live).
    let playhead: TimeInterval
    let zoom: CGFloat

    var body: some View {
        let art = BackgroundArt(rawValue: state.backgroundID)
        let isPortrait = size.height >= size.width
        ZStack {
            Theme.background
            Canvas { ctx, sz in
                switch art {
                case .streets:
                    BackgroundArtRenderer.drawStreets(
                        &ctx, size: sz, roads: StreetMapModel.shared.roads,
                        angle: BackgroundArtRenderer.streetsAutoAngle(at: Date()),
                        contrast: state.backgroundContrast)
                case .topo:
                    if let path = ElevationModel.shared.contourPath {
                        BackgroundArtRenderer.drawTopoContours(
                            &ctx, size: sz, path: path,
                            traceSize: ElevationModel.traceSize,
                            date: Date(), contrast: state.backgroundContrast)
                    }
                case .procedural:
                    let path = BackgroundArtRenderer.topoContours(size: sz)
                    BackgroundArtRenderer.drawTopo(&ctx, size: sz, path: path, date: Date(),
                                                   contrast: state.backgroundContrast)
                case .neon:
                    if !state.lightMode {
                        BackgroundArtRenderer.drawNeon(
                            &ctx, size: sz,
                            phase: BackgroundArtRenderer.neonAutoPhase(at: Date()),
                            contrast: state.backgroundContrast)
                    }
                case .slope:
                    BackgroundArtRenderer.drawSlope(
                        &ctx, size: sz, samples: samples, playhead: playhead,
                        pauseMarks: pauseMarks,
                        metric: state.unitIsMetric, family: state.appFont,
                        contrast: state.backgroundContrast)
                case .route:
                    BackgroundArtRenderer.drawRoute(
                        &ctx, size: sz, samples: samples, playhead: playhead,
                        zoom: zoom, contrast: state.backgroundContrast)
                default:
                    break
                }
            }
            WayfindingView(state: state,
                           townSize: min(max(size.width * 0.16, 44), 120),
                           alignment: .leading,
                           speedSignScale: isPortrait ? 2 : 1,
                           displayDate: displayDate,
                           edgeAligned: art == .route) { EmptyView() }
                .padding(.horizontal, 28)
                .padding(.vertical, art == .route ? 12 : 0)
                .frame(width: size.width, height: size.height, alignment: .leading)
        }
        .frame(width: size.width, height: size.height)
    }
}
