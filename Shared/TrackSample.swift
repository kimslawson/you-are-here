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
}
