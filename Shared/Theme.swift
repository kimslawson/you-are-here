import SwiftUI

/// The user-selectable UI typeface (Settings ▸ Font). Each case maps SwiftUI
/// weights onto concrete faces of that family; the choice travels to the
/// widget process inside `ContentState.fontID` (no App Group needed).
enum AppFont: String, CaseIterable, Identifiable, Codable {
    /// Helvetica Neue (ships with iOS) — the default. A true neo-grotesque in
    /// the lineage of transit/road signage (Highway Gothic, Helvetica on the
    /// NYC subway).
    case helvetica
    /// The system font (SF Pro).
    case sanFrancisco
    /// Fontsmith's wayfinding face (commercial; bundled under the user's
    /// license — Regular + Bold only).
    case fsMillbank
    /// Open-source (OFL) digitization of U.S. Highway Gothic, bundled.
    case overpass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .helvetica:    return "Helvetica Neue"
        case .sanFrancisco: return "San Francisco"
        case .fsMillbank:   return "FS Millbank"
        case .overpass:     return "Overpass"
        }
    }

    /// PostScript name of the face for a weight; nil = use the system font.
    func face(for weight: Font.Weight) -> String? {
        switch self {
        case .sanFrancisco:
            return nil
        case .helvetica:
            switch weight {
            case .bold, .heavy, .black: return "HelveticaNeue-Bold"
            case .semibold, .medium:    return "HelveticaNeue-Medium"
            case .light, .thin:         return "HelveticaNeue-Light"
            default:                    return "HelveticaNeue"
            }
        case .fsMillbank:
            // Wayfinding faces are sturdy by design: Regular covers the small
            // lines, Bold the emphasis weights.
            switch weight {
            case .bold, .heavy, .black, .semibold: return "FSMillbankWeb-Bold"
            default:                               return "FSMillbankWeb"
            }
        case .overpass:
            switch weight {
            case .bold, .heavy, .black: return "Overpass-Bold"
            case .semibold:             return "Overpass-SemiBold"
            case .medium:               return "Overpass-Medium"
            default:                    return "Overpass-Regular"
            }
        }
    }
}

/// Central place for the wayfinding look: a grotesque sans, bright-on-dark
/// palette, and the white "flash" used when a field changes.
enum Theme {

    // MARK: Colors
    static let background = Color.black
    /// Primary bright text (slightly warm off-white for comfort on OLED).
    static let primary = Color(red: 0.97, green: 0.97, blue: 0.95)
    /// Secondary / small text.
    static let secondary = Color(red: 0.74, green: 0.76, blue: 0.80)
    /// Pure white flash for a value that just changed.
    static let flash = Color.white
    /// Muted color for the "no signal" state.
    static let muted = Color(red: 0.55, green: 0.45, blue: 0.30)

    // MARK: Fonts
    static func font(size: CGFloat, weight: Font.Weight = .regular, family: AppFont = .helvetica) -> Font {
        if let face = family.face(for: weight) {
            return Font.custom(face, size: size)
        }
        return Font.system(size: size, weight: weight, design: .default)
    }

    /// Color for a field, flashing white on change.
    static func textColor(changed: Bool, base: Color = primary) -> Color {
        changed ? flash : base
    }
}

// Font sugar for views that render a ContentState (app screen, Live Activity,
// PiP frames): the state carries the chosen family.
extension LocationActivityAttributes.ContentState {
    var appFont: AppFont { AppFont(rawValue: fontID) ?? .helvetica }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Theme.font(size: size, weight: weight, family: appFont)
    }
}
