import AVFoundation
import AVKit
import Combine
import SwiftUI

/// Floats the readout over other apps via Picture in Picture (opt-in).
///
/// iOS has no floating-panel API for arbitrary views — only video may float —
/// so this renders `WayfindingView` into video frames: each engine state change
/// is rasterized (`ImageRenderer`) into a wide banner, converted to a
/// `CMSampleBuffer`, and enqueued on an `AVSampleBufferDisplayLayer` driving an
/// `AVPictureInPictureController`. The PiP window adopts the banner's aspect
/// ratio, and its play/pause control maps onto park/resume. PiP starts
/// automatically when the user leaves the app (and the readout isn't parked).
@MainActor
final class PiPManager: NSObject, ObservableObject {

    private weak var engine: LocationEngine?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var controller: AVPictureInPictureController?
    private let playbackDelegate = PiPPlaybackDelegate()
    private var cancellables = Set<AnyCancellable>()
    private var enabled = false

    /// Frames render at `renderScale`× so text stays crisp when the window is
    /// pinched large. The canvas geometry lives on `PiPFrameView`.
    private let renderScale: CGFloat = 3

    func bind(to engine: LocationEngine) {
        guard self.engine !== engine else { return }
        self.engine = engine
        cancellables.removeAll()

        engine.$state
            .sink { [weak self] state in self?.renderFrame(state) }
            .store(in: &cancellables)

        // Keep the PiP play/pause control in sync with park/resume.
        engine.$isPaused
            .removeDuplicates()
            .sink { [weak self] paused in
                self?.playbackDelegate.isPaused = paused
                self?.controller?.invalidatePlaybackState()
            }
            .store(in: &cancellables)

        playbackDelegate.onSetPlaying = { [weak self] playing in
            self?.engine?.setPaused(!playing)
        }
    }

    /// Called by the (hidden) hosting view once its backing layer exists.
    func adopt(layer: AVSampleBufferDisplayLayer) {
        guard displayLayer !== layer else { return }
        displayLayer = layer
        if enabled { activate() }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { activate() } else { deactivate() }
    }

    /// The system starts PiP automatically when the app is backgrounded, but it
    /// does NOT stop it when the app returns to the foreground (e.g. via the
    /// Live Activity or the app icon) — the floating window would sit on top of
    /// the full-screen app showing the same thing. Call on scene activation.
    func dismissForForeground() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
    }

    private func activate() {
        guard controller == nil, let displayLayer,
              AVPictureInPictureController.isPictureInPictureSupported() else { return }

        // PiP rides on the playback audio session; mixWithOthers so enabling
        // this never ducks or stops the user's music.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .moviePlayback, options: [.mixWithOthers])

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: playbackDelegate)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true   // hide skip controls
        self.controller = controller

        playbackDelegate.isPaused = engine?.isPaused ?? false
        // Prime the layer so PiP is "possible" before the first state change.
        if let state = engine?.state { renderFrame(state) }
    }

    private func deactivate() {
        controller?.stopPictureInPicture()
        controller?.contentSource = nil
        controller = nil
        displayLayer?.flushAndRemoveImage()
    }

    // MARK: Frame pipeline

    /// Re-render the current readout, e.g. after the window-size setting flips
    /// (the PiP window animates to the new aspect ratio on the next frame).
    func redraw() {
        if let state = engine?.state { renderFrame(state) }
    }

    private func renderFrame(_ state: LocationActivityAttributes.ContentState) {
        guard enabled, controller != nil else { return }

        let large = UserDefaults.standard.bool(forKey: SettingsKey.pipLargeWindow)
        let renderer = ImageRenderer(content: PiPFrameView(state: state, large: large))
        renderer.scale = renderScale
        guard let image = renderer.cgImage,
              let pixelBuffer = Self.pixelBuffer(from: image),
              let sampleBuffer = Self.sampleBuffer(from: pixelBuffer) else { return }
        enqueue(sampleBuffer)
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard let displayLayer else { return }
        if #available(iOS 17.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sampleBuffer)
        } else {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var out: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width, height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private static func sampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &format) == noErr, let format else { return nil }

        // Stamped "now" so the layer shows each frame as soon as it arrives.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}

/// The system calls these to drive the PiP window's playback UI. Kept off the
/// main actor (AVKit calls on the main thread, but the protocol is nonisolated);
/// `PiPManager` pushes state in and receives commands via `onSetPlaying`.
private final class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    var isPaused = false
    var onSetPlaying: ((Bool) -> Void)?

    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        onSetPlaying?(playing)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        isPaused
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // "Live": no duration, no scrubber.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// What each PiP video frame shows: the shared wayfinding layout on a wide
/// banner. Scaled-up speed sign, same as the other cramped layouts. Two
/// canvases (the frame's shape IS the window's aspect ratio): small is a
/// ≈3:1 strip; large is 2:1 with proportionally bigger type — more screen,
/// more legible.
struct PiPFrameView: View {
    let state: LocationActivityAttributes.ContentState
    var large = false

    var body: some View {
        ZStack {
            Theme.background
            backdrop
            // Small trades a bit of town size for bigger secondary lines —
            // at strip size the small type is what goes illegible first.
            WayfindingView(state: state, townSize: large ? 84 : 50,
                           alignment: .leading, speedSignScale: 2,
                           smallScale: large ? 1 : 1.25)
                .padding(.horizontal, large ? 30 : 22)
                .padding(.vertical, large ? 18 : 14)
        }
        .frame(width: 480, height: large ? 240 : 160)
    }

    /// The aesthetic backdrop, static per frame (frames regenerate ~1/s while
    /// driving, which animates it gently). Rendered in the app process, so
    /// streets can use the shared fetch model.
    @ViewBuilder
    private var backdrop: some View {
        let art = BackgroundArt(rawValue: state.backgroundID)
        if art == .streets || art == .topo || art == .procedural
            || (art == .neon && !state.lightMode) {
            Canvas { ctx, size in
                switch art {
                case .streets:
                    BackgroundArtRenderer.drawStreets(
                        &ctx, size: size, roads: StreetMapModel.shared.roads,
                        angle: BackgroundArtRenderer.streetsAutoAngle(at: Date()),
                        contrast: state.backgroundContrast)
                case .topo:
                    if let path = ElevationModel.shared.contourPath {
                        BackgroundArtRenderer.drawTopoContours(
                            &ctx, size: size, path: path,
                            traceSize: ElevationModel.traceSize,
                            date: Date(), contrast: state.backgroundContrast)
                    }
                case .procedural:
                    let path = BackgroundArtRenderer.topoContours(size: size)
                    BackgroundArtRenderer.drawTopo(&ctx, size: size, path: path, date: Date(),
                                                   contrast: state.backgroundContrast)
                case .neon:
                    BackgroundArtRenderer.drawNeon(
                        &ctx, size: size,
                        phase: BackgroundArtRenderer.neonAutoPhase(at: Date()),
                        contrast: state.backgroundContrast)
                default:
                    break
                }
            }
        }
    }
}

/// Invisible view whose backing layer is the `AVSampleBufferDisplayLayer` PiP
/// draws from. AVKit wants the layer in the app's view hierarchy; `ContentView`
/// embeds this at 1×1 pt and near-zero opacity.
struct PiPHostView: UIViewRepresentable {
    let manager: PiPManager

    func makeUIView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.sampleBufferLayer.videoGravity = .resizeAspect
        manager.adopt(layer: view.sampleBufferLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferHostView, context: Context) {}
}

final class SampleBufferHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var sampleBufferLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

#Preview {
    PiPFrameView(state: .placeholder)
}
