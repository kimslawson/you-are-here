import Foundation

/// An optional readout on the bottom line. The user picks any subset (Settings ▸
/// Complications); they render in this declaration order, dot-separated. When
/// none are chosen the bottom line is empty but keeps its height (the pause
/// button holds the row), so the town/road lines don't move.
enum Complication: String, CaseIterable, Identifiable, Codable {
    case altitude
    case compass
    case time
    case temperature

    var id: String { rawValue }

    var label: String {
        switch self {
        case .altitude:    return "Altitude"
        case .compass:     return "Compass"
        case .time:        return "Time"
        case .temperature: return "Temperature"
        }
    }

    /// The choice travels to the widget inside `ContentState` as a comma-joined
    /// string of raw values, in display order.
    static func decode(_ raw: String) -> [Complication] {
        raw.split(separator: ",").compactMap { Complication(rawValue: String($0)) }
    }

    static func encode(_ list: [Complication]) -> String {
        // Keep declaration order regardless of selection order.
        allCases.filter(list.contains).map(\.rawValue).joined(separator: ",")
    }

    /// The default matches the app's original bottom line.
    static let defaultRaw = "altitude,compass"
}
