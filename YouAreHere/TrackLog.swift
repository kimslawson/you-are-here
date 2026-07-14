import Foundation

/// The drive's recorded trail, feeding the Slope/Route backgrounds and the
/// app's scrub-to-retrace gesture.
///
/// The trail's time axis is **active time** — seconds of un-parked recording.
/// Parking closes a segment and freezes the clock; resuming opens the next
/// segment. Paused wall-clock time never appears on the axis, so segments sit
/// back-to-back (Slope marks each seam with its dashed line) and the renderers
/// draw them as separate strokes, never connected.
///
/// A reference type so views can read `samples` lazily inside their own redraws
/// (Canvas, PiP frame) without the engine having to `@Published` — and re-diff —
/// a steadily growing array on every tick. Session-scoped: a cold launch starts
/// a fresh trail, matching how pause and the heading unwrap already reset.
@MainActor
final class TrackLog {
    private(set) var samples: [TrackSample] = []
    /// Active-time position of each park — the seams between segments.
    private(set) var pauseMarks: [TimeInterval] = []

    /// Active seconds accumulated in *closed* segments.
    private var activeOffset: TimeInterval = 0
    /// Wall-clock start of the open segment; nil while parked (clock frozen).
    private var segmentStart: Date?
    private var currentSegment = 0

    /// At most one point this often, so storage stays bounded regardless of the
    /// refresh rate (1 s ticks record roughly every 4th).
    private let minSpacing: TimeInterval = 4
    /// Hard cap (~12 h at `minSpacing`); the oldest points drop past it. On a
    /// continuous drive longer than that the trail no longer reaches the very
    /// first recording.
    private let maxSamples = 10_800

    /// Where "now" sits on the active axis: frozen while parked, advancing with
    /// the wall clock while recording. The live playhead.
    var activeDuration: TimeInterval {
        activeOffset + (segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// Append a point, honoring the minimum spacing and the cap. Callers only
    /// record while live (the engine ticks only when not parked); the first
    /// point after a park (re)opens the segment clock.
    func record(_ sample: TrackSample) {
        if let last = samples.last,
           sample.date.timeIntervalSince(last.date) < minSpacing { return }
        var s = sample
        if segmentStart == nil { segmentStart = s.date }
        s.activeTime = activeOffset + s.date.timeIntervalSince(segmentStart!)
        s.segment = currentSegment
        samples.append(s)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Close the open segment at a park: freeze the active clock and drop a
    /// seam marker. No-op while already parked or before anything was recorded.
    func markPause() {
        guard let segmentStart else { return }
        activeOffset += Date().timeIntervalSince(segmentStart)
        self.segmentStart = nil
        currentSegment += 1
        pauseMarks.append(activeOffset)
        if pauseMarks.count > 512 { pauseMarks.removeFirst(pauseMarks.count - 512) }
    }

    /// The recorded readout at or before `t` on the active axis (the nearest
    /// earlier point), for scrubbing. Falls back to the first sample for a `t`
    /// before the trail begins; nil only when nothing has been recorded yet.
    func sample(atActive t: TimeInterval) -> TrackSample? {
        guard !samples.isEmpty else { return nil }
        // activeTime is monotonic, so binary-search the last <= t.
        var lo = 0, hi = samples.count - 1, found: TrackSample?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if samples[mid].activeTime <= t {
                found = samples[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found ?? samples.first
    }

    var first: TrackSample? { samples.first }
    /// True once there's enough of a trail to pan through.
    var isScrubable: Bool { samples.count >= 2 }
}
