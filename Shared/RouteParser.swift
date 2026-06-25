import Foundation

/// Best-effort extraction of a numbered route from a placemark's road string.
///
/// Apple's reverse geocoder doesn't hand back a structured route number, so we
/// pattern-match the thoroughfare text (e.g. "I-80", "US Highway 50",
/// "Interstate 5", "CA-89", "State Route 89"). This is heuristic by nature;
/// when nothing matches we simply show the plain road name with no shield.
enum RouteParser {

    static func parse(road: String?, stateAbbrev: String?) -> RouteRef? {
        guard let raw = road?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // Interstate: "I-80", "I 80", "Interstate 80"
        if let n = firstMatch(in: raw, pattern: #"\b(?:I|Interstate)[\s-]?(\d{1,3})\b"#) {
            return RouteRef(kind: .interstate, number: n, stateAbbrev: nil)
        }

        // US highway: "US-50", "US 50", "U.S. 50", "US Highway 50", "US Route 50"
        if let n = firstMatch(in: raw, pattern: #"\b(?:US|U\.S\.)[\s-]?(?:Highway|Hwy|Route|Rte)?[\s-]?(\d{1,3})\b"#) {
            return RouteRef(kind: .usHighway, number: n, stateAbbrev: nil)
        }

        // State highway with explicit state abbrev: "CA-89", "NV 431"
        if let (abbrev, n) = firstPairMatch(in: raw, pattern: #"\b([A-Z]{2})[\s-](\d{1,3})\b"#) {
            return RouteRef(kind: .stateHighway, number: n, stateAbbrev: abbrev)
        }

        // Generic state route: "State Route 89", "SR 89", "Highway 89", "Hwy 89", "Route 89"
        if let n = firstMatch(in: raw, pattern: #"\b(?:State Route|State Hwy|SR|Highway|Hwy|Route|Rte)[\s-]?(\d{1,3})\b"#) {
            return RouteRef(kind: .stateHighway, number: n, stateAbbrev: stateAbbrev)
        }

        return nil
    }

    /// True when the parsed route IS the road (i.e. the thoroughfare itself is a
    /// numbered route, so there's no separate local street name to show).
    static func roadIsJustRoute(road: String?, route: RouteRef?) -> Bool {
        guard let route, let road = road?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let label = Formatting.routeLabel(route)
        // Compare loosely, ignoring separators/case.
        func normalize(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
        }
        return normalize(road) == normalize(label) || normalize(road).contains(normalize(route.number)) && normalize(road).count <= normalize(label).count + 2
    }

    // MARK: - Regex helpers

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func firstPairMatch(in text: String, pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 3,
              let r1 = Range(match.range(at: 1), in: text),
              let r2 = Range(match.range(at: 2), in: text) else { return nil }
        return (String(text[r1]), String(text[r2]))
    }
}
