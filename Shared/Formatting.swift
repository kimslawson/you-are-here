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

    /// Posted speed limit as a whole number in the display unit, e.g. 45 (mph)
    /// or 72 (km/h). Returns nil when unknown.
    static func speedLimitValue(kmh: Double?, metric: Bool) -> Int? {
        guard let kmh else { return nil }
        return Int((metric ? kmh : kmh * 0.621371).rounded())
    }

    /// The unit abbreviation for the current setting.
    static func speedUnit(metric: Bool) -> String { metric ? "km/h" : "mph" }

    /// Current time, no seconds. 24-hour "17:03" or 12-hour "5:03 PM".
    static func timeString(_ date: Date, clock24: Bool) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        if clock24 {
            return String(format: "%d:%02d", h, m)
        }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
    }

    /// Trip distance in the display unit: one decimal under 100 ("12.4 mi" /
    /// "20.0 km"), whole above ("104 mi"). Em dash when unknown.
    static func distanceString(meters: Double?, metric: Bool) -> String {
        guard let meters else { return "—" }
        let value = metric ? meters / 1000 : meters / 1609.344
        let unit = metric ? "km" : "mi"
        if value < 99.95 {
            return String(format: "%.1f %@", value, unit)
        }
        return "\(Int(value.rounded())) \(unit)"
    }

    /// Whole-degree temperature in the display unit, e.g. "54°F" / "12°C". Em
    /// dash unknown. (`metric` here means Celsius — the temperature-unit flag.)
    static func temperatureString(celsius: Double?, metric: Bool) -> String {
        guard let celsius else { return "—" }
        let value = metric ? celsius : celsius * 9 / 5 + 32
        return "\(Int(value.rounded()))°\(metric ? "C" : "F")"
    }

    /// Display-unit whole-degree value, for the >1° change comparison.
    static func temperatureValue(celsius: Double?, metric: Bool) -> Int? {
        guard let celsius else { return nil }
        return Int((metric ? celsius : celsius * 9 / 5 + 32).rounded())
    }
}
