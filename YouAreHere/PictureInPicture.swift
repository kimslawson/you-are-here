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

    /// Banner canvas in points (≈3:1 — wide and short, unlike a video player).
    /// Rendered at `renderScale`× so text stays crisp when the window is pinched
    /// large.
    static let canvasSize = CGSize(width: 480, height: 160)
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

    private func renderFrame(_ state: LocationActivityAttributes.ContentState) {
        guard enabled, controller != nil else { return }

        let renderer = ImageRenderer(content: PiPFrameView(state: state))
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

/// What each PiP video frame shows: the shared wayfinding layout on a wide,
/// short banner. Scaled-up speed sign, same as the other cramped layouts.
struct PiPFrameView: View {
    let state: LocationActivityAttributes.ContentState

    var body: some View {
        ZStack {
            Theme.background
            WayfindingView(state: state, townSize: 56, alignment: .leading, speedSignScale: 2)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: PiPManager.canvasSize.width, height: PiPManager.canvasSize.height)
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
