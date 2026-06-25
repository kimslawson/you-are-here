import Foundation
import CoreMotion
import CoreLocation

/// Fuses GPS altitude (absolute but slow/noisy) with the barometric altimeter
/// (smooth and responsive but only *relative*). The barometer gives us fast,
/// jitter-free changes; GPS keeps the absolute value honest.
///
/// Strategy: track a `baseline` such that
///     altitude = baseline + barometricRelativeAltitude
/// Each time we get a good GPS fix we gently re-anchor the baseline toward
/// `gpsAltitude - barometricRelative`, low-pass filtered so it doesn't jump.
final class AltitudeFuser {
    private let altimeter = CMAltimeter()
    private var baroRelative: Double = 0      // meters since altimeter start
    private var baseline: Double?             // meters
    private var hasBaro = false

    /// Smoothing for GPS re-anchoring (0 = ignore GPS, 1 = snap to GPS).
    private let anchorGain = 0.15

    var isBarometerAvailable: Bool { CMAltimeter.isRelativeAltitudeAvailable() }

    func start() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            self.baroRelative = data.relativeAltitude.doubleValue
            self.hasBaro = true
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
    }

    /// Feed a GPS fix; only fixes with a sane vertical accuracy re-anchor.
    func ingestGPS(_ location: CLLocation) {
        guard location.verticalAccuracy > 0, location.verticalAccuracy < 30 else { return }
        let target = location.altitude - (hasBaro ? baroRelative : 0)
        if let current = baseline {
            baseline = current + (target - current) * anchorGain
        } else {
            baseline = target
        }
    }

    /// Current best-estimate absolute altitude in meters, or nil if unknown.
    var altitudeMeters: Double? {
        guard let baseline else { return nil }
        return baseline + (hasBaro ? baroRelative : 0)
    }
}
