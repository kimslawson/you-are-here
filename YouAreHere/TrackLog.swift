import Foundation

/// The drive's recorded trail, feeding the Slope background's sparkline and the
/// app's scrub-to-retrace gesture.
///
/// A reference type so views can read `samples` lazily inside their own redraws
/// (Canvas, PiP frame) without the engine having to `@Published` — and re-diff —
/// a steadily growing array on every tick. Session-scoped: a cold launch starts
/// a fresh trail, matching how pause and the heading unwrap already reset.
@MainActor
final class TrackLog {
    private(set) var samples: [TrackSample] = []

    /// At most one point this often, so storage stays bounded regardless of the
    /// refresh rate (1 s ticks record roughly every 4th).
    private let minSpacing: TimeInterval = 4
    /// Hard cap (~12 h at `minSpacing`); the oldest points drop past it. On a
    /// continuous drive longer than that the trail no longer reaches the very
    /// first recording.
    private let maxSamples = 10_800

    /// Append a point, honoring the minimum spacing and the cap. Callers only
    /// record while live (the engine ticks only when not parked), so the trail
    /// simply doesn't grow while parked — which is what we want.
    func record(_ sample: TrackSample) {
        if let last = samples.last,
           sample.date.timeIntervalSince(last.date) < minSpacing { return }
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// The recorded readout at or before `date` (the nearest earlier point), for
    /// scrubbing. Falls back to the first sample for a `date` before the trail
    /// begins; nil only when nothing has been recorded yet.
    func sample(at date: Date) -> TrackSample? {
        guard !samples.isEmpty else { return nil }
        // Samples are appended in time order, so binary-search the last <= date.
        var lo = 0, hi = samples.count - 1, found: TrackSample?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if samples[mid].date <= date {
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
