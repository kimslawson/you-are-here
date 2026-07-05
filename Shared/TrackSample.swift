import Foundation

/// One point along the drive so far: the whole displayed readout at a moment,
/// timestamped. The Slope background plots `altitudeMeters` over `date`; the
/// app's scrub gesture uses the rest (town, road, route, heading, temperature)
/// to retrace the readout at any past point on the trail.
///
/// Value type with no protocol conformances by design — it's captured by value
/// into the floating-window render closure, so there's nothing to synchronize.
struct TrackSample {
    var date: Date
    var altitudeMeters: Double?
    var town: String
    var road: String
    var route: RouteRef?
    var headingDegrees: Double?
    var headingContinuous: Double?
    var temperatureC: Double?
}
