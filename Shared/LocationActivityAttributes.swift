import Foundation
import ActivityKit

/// The kind of numbered route, used to pick the correct shield artwork.
enum RouteKind: String, Codable, Hashable {
    case interstate     // e.g. I-80
    case usHighway      // e.g. US-50
    case stateHighway   // e.g. CA-89
}

/// A parsed numbered route reference (the bit that gets a shield).
struct RouteRef: Codable, Hashable {
    var kind: RouteKind
    var number: String          // "80", "50", "89"
    var stateAbbrev: String?    // for state highways, e.g. "CA"
}

/// Shared between the app and the widget extension. Defines both the static
/// attributes of the Live Activity and the per-update `ContentState`.
struct LocationActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Town / locality. Empty string while unknown.
        var town: String
        /// Local road / thoroughfare name.
        var road: String
        /// Numbered route, if we're on one. Drives the shield.
        var route: RouteRef?

        /// Canonical altitude in meters; formatted per `unitIsMetric` at render.
        var altitudeMeters: Double?
        /// True-north heading in degrees [0, 360). Used for the text + cardinal.
        var headingDegrees: Double?
        /// Continuous (unwrapped, accumulating) heading angle for the rotating
        /// arrow. The engine keeps it continuous so consecutive values differ by
        /// the *shortest* signed step — both the app's container animation and
        /// ActivityKit's snapshot interpolation then rotate the short way across
        /// north (a raw 350°→10° would otherwise spin backwards 340°).
        var headingContinuous: Double?

        /// Whether the user prefers metric. Carried in state so the widget
        /// renders correctly without needing a shared app group.
        var unitIsMetric: Bool
        /// Chosen UI typeface (`AppFont` raw value); carried for the same reason.
        var fontID: String
        /// Light mode (inverted palette); carried for the same reason.
        var lightMode: Bool
        /// Custom flash color as "RRGGBB", or nil for the default flash.
        var flashHex: String?
        /// False when we have no network and names are stale.
        var hasSignal: Bool
        /// True when "parked" — sensors are frozen to save battery.
        var isPaused: Bool
        /// Posted speed limit in km/h (canonical; formatted per unit at render).
        /// nil when unknown / disabled.
        var speedLimitKmh: Double?

        // MARK: Flash flags
        // Set `true` on the single update where the field just changed, so the
        // widget can render that field in pure white for one ~1s frame.
        var townChanged: Bool
        var roadChanged: Bool
        var headingChanged: Bool
        var speedLimitChanged: Bool

        /// Big-line text while no town is known, reflecting *why* it's unknown:
        /// parked (not looking), offline, or actively locating. ASCII periods,
        /// not "…" — some bundled fonts ship empty glyphs for typographic
        /// punctuation (see SeparatorDot).
        var townPlaceholder: String {
            if isPaused { return "Paused" }
            return hasSignal ? "Locating..." : "No signal"
        }

        static var placeholder: ContentState {
            ContentState(
                town: "Truckee",
                road: "Donner Pass Rd",
                route: RouteRef(kind: .interstate, number: "80", stateAbbrev: nil),
                altitudeMeters: 1816,
                headingDegrees: 305,
                headingContinuous: 305,
                unitIsMetric: false,
                fontID: AppFont.helvetica.rawValue,
                lightMode: false,
                flashHex: nil,
                hasSignal: true,
                isPaused: false,
                speedLimitKmh: 72,
                townChanged: false,
                roadChanged: false,
                headingChanged: false,
                speedLimitChanged: false
            )
        }
    }

    /// Static title (unused on screen, but ActivityAttributes needs >= 0 stored
    /// properties; kept for future use / debugging).
    var title: String
}
