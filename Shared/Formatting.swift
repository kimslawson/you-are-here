import Foundation

/// Pure formatting helpers shared by the app UI and the widget so both render
/// identical strings. No state, no side effects.
enum Formatting {

    private static let cardinals = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// Eight-point cardinal letter for a heading in degrees.
    static func cardinal(_ degrees: Double) -> String {
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 22.5) / 45) % 8
        return cardinals[index]
    }

    /// e.g. "NW 305°". Returns an em dash when heading is unknown.
    static func headingString(_ degrees: Double?) -> String {
        guard let degrees else { return "—" }
        let whole = Int(degrees.rounded()) % 360
        return "\(cardinal(degrees)) \(whole)°"
    }

    private static let altitudeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// e.g. "5,958 ft" or "1,816 m". Em dash when unknown.
    static func altitudeString(meters: Double?, metric: Bool) -> String {
        guard let meters else { return "—" }
        if metric {
            let value = altitudeFormatter.string(from: NSNumber(value: Int(meters.rounded()))) ?? "\(Int(meters.rounded()))"
            return "\(value) m"
        } else {
            let feet = Int((meters * 3.28084).rounded())
            let value = altitudeFormatter.string(from: NSNumber(value: feet)) ?? "\(feet)"
            return "\(value) ft"
        }
    }

    /// Short label for a route shield, e.g. "I-80", "US-50", "CA-89", "89".
    static func routeLabel(_ route: RouteRef) -> String {
        switch route.kind {
        case .interstate:
            return "I-\(route.number)"
        case .usHighway:
            return "US-\(route.number)"
        case .stateHighway:
            if let abbrev = route.stateAbbrev, !abbrev.isEmpty {
                return "\(abbrev)-\(route.number)"
            }
            return route.number
        }
    }
}
