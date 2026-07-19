import Foundation

/// One point along the drive so far: the whole displayed readout at a moment,
/// timestamped. The Slope background plots `altitudeMeters` over `date`; the
/// app's scrub gesture uses the rest (town, road, route, heading, temperature)
/// to retrace the readout at any past point on the trail.
///
/// A value type — it's captured by value into the floating-window render
/// closure, so there's nothing to synchronize. Codable so whole trails can be
/// saved to disk (RouteStore) and exported as parseable JSON.
struct TrackSample: Codable {
    var date: Date
    var altitudeMeters: Double?
    /// GPS position, for the Route background's 2-D path. nil when no fix.
    var latitude: Double?
    var longitude: Double?
    var town: String
    var road: String
    var route: RouteRef?
    var headingDegrees: Double?
    var headingContinuous: Double?
    var temperatureC: Double?
    /// Trip odometer at this moment, meters — retraces while scrubbing.
    /// Optional so routes saved before the field existed still decode.
    var tripDistanceMeters: Double?

    // Set by TrackLog.record — callers leave the defaults.
    /// Seconds of *active* (un-parked) recording elapsed at this sample: the
    /// trail's time axis. Paused wall-clock time is excised, so scrubbing and
    /// playback jump straight across a park instead of dwelling in the gap.
    var activeTime: TimeInterval = 0
    /// Recording segment index. Parking closes a segment, resuming opens the
    /// next; renderers never connect points across segments.
    var segment: Int = 0

    private enum CodingKeys: String, CodingKey {
        case date, altitudeMeters, latitude, longitude, town, road, route,
             headingDegrees, headingContinuous, temperatureC, tripDistanceMeters,
             activeTime, segment
    }

    /// Custom encode only (decoding stays synthesized): round each number to
    /// the precision that matters before it hits JSON — raw doubles print 15+
    /// digits and balloon saved/exported routes for nothing. Lat/lon keep six
    /// decimals (≈0.11 m); everything else one decimal or whole units, well
    /// past display precision.
    func encode(to encoder: Encoder) throws {
        func rounded(_ v: Double, _ places: Int) -> Double {
            let f = pow(10, Double(places))
            return (v * f).rounded() / f
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(altitudeMeters.map { rounded($0, 1) }, forKey: .altitudeMeters)
        try c.encodeIfPresent(latitude.map { rounded($0, 6) }, forKey: .latitude)
        try c.encodeIfPresent(longitude.map { rounded($0, 6) }, forKey: .longitude)
        try c.encode(town, forKey: .town)
        try c.encode(road, forKey: .road)
        try c.encodeIfPresent(route, forKey: .route)
        try c.encodeIfPresent(headingDegrees.map { rounded($0, 1) }, forKey: .headingDegrees)
        try c.encodeIfPresent(headingContinuous.map { rounded($0, 1) }, forKey: .headingContinuous)
        try c.encodeIfPresent(temperatureC.map { rounded($0, 1) }, forKey: .temperatureC)
        try c.encodeIfPresent(tripDistanceMeters.map { $0.rounded() }, forKey: .tripDistanceMeters)
        try c.encode(rounded(activeTime, 1), forKey: .activeTime)
        try c.encode(segment, forKey: .segment)
    }
}
