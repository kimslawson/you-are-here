import SwiftUI
import UIKit

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
    /// Michael Adams' recreations of the FHWA sign series (freeware,
    /// non-commercial), bundled: Series D + E + E Modified.
    case roadgeek
    /// DIN 1451 Mittelschrift — German road signage — via its Roadgeek 2005
    /// recreation (same license), bundled. Single weight, like the real signs.
    case din1451
    /// DIN 1451 Engschrift — the condensed variant (long names on narrow
    /// signs) — same Roadgeek recreation and license. Single weight.
    case din1451Eng
    /// Grotesque modeled on California highway signage (OFL), bundled.
    case barlow
    /// Airbus-commissioned cockpit-display face (OFL), bundled.
    case b612
    /// Braille Institute's maximum-disambiguation face (OFL), bundled.
    case atkinson
    /// The workhorse open-source screen grotesque (OFL), bundled.
    case inter
    /// Comic Neue (OFL) — the open-source Comic Sans homage. Not listed in the
    /// Settings picker: it's the Easter egg (tap the app screen 10 times).
    case comic

    var id: String { rawValue }

    /// What the Settings picker offers; the Easter-egg face stays hidden.
    static var selectable: [AppFont] { allCases.filter { $0 != .comic } }

    var label: String {
        switch self {
        case .helvetica:    return "Helvetica Neue"
        case .sanFrancisco: return "San Francisco"
        case .fsMillbank:   return "FS Millbank"
        case .overpass:     return "Overpass"
        case .roadgeek:     return "Roadgeek 2005"
        case .din1451:      return "DIN 1451"
        case .din1451Eng:   return "DIN 1451 Engschrift"
        case .barlow:       return "Barlow"
        case .b612:         return "B612"
        case .atkinson:     return "Atkinson Hyperlegible"
        case .inter:        return "Inter"
        case .comic:        return "Comic Sans (basically)"
        }
    }

    /// Optical vertical correction for the big town line, as a fraction of the
    /// town point size (negative = up). Metric centering leaves title-case
    /// names looking high-set (see WayfindingView.townLine), so most families
    /// get a -5% lift — but Overpass and FS Millbank already carry extra
    /// ascent in their vertical metrics and need almost none to sit level.
    var townOffsetFactor: CGFloat {
        switch self {
        case .overpass, .fsMillbank: return -0.01
        default:                     return -0.05
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
        // FHWA "weights" are really widths: D (narrow) for the small lines,
        // E for semibold accents, E Modified (the interstate face) for bold.
        case .roadgeek:
            switch weight {
            case .bold, .heavy, .black: return "Roadgeek2005SeriesEM"
            case .semibold:             return "Roadgeek2005SeriesE"
            default:                    return "Roadgeek2005SeriesD"
            }
        // German signs use a single weight; every SwiftUI weight maps to it.
        case .din1451:
            return "Roadgeek2005Mittelschrift"
        case .din1451Eng:
            return "Roadgeek2005Engschrift"
        case .barlow:
            switch weight {
            case .bold, .heavy, .black: return "Barlow-Bold"
            case .semibold:             return "Barlow-SemiBold"
            case .medium:               return "Barlow-Medium"
            default:                    return "Barlow-Regular"
            }
        case .inter:
            switch weight {
            case .bold, .heavy, .black: return "Inter-Bold"
            case .semibold:             return "Inter-SemiBold"
            case .medium:               return "Inter-Medium"
            default:                    return "Inter-Regular"
            }
        // Two-weight families: Regular carries the small lines, Bold the rest.
        case .b612:
            switch weight {
            case .bold, .heavy, .black, .semibold: return "B612-Bold"
            default:                               return "B612-Regular"
            }
        case .atkinson:
            switch weight {
            case .bold, .heavy, .black, .semibold: return "AtkinsonHyperlegible-Bold"
            default:                               return "AtkinsonHyperlegible-Regular"
            }
        case .comic:
            switch weight {
            case .bold, .heavy, .black, .semibold: return "ComicNeue-Bold"
            default:                               return "ComicNeue-Regular"
            }
        }
    }
}

/// Central place for the wayfinding look: a grotesque sans, bright-on-dark
/// palette (invertible to light), and the "flash" used when a field changes.
enum Theme {

    // MARK: Appearance flags
    // Per-process, like the font choice: the app applies them from UserDefaults
    // (LocationEngine), the widget from ContentState at render time — no App
    // Group needed. Views read the computed colors below, so a re-render after
    // apply() picks the new palette up everywhere.
    private(set) static var isLight = false
    private(set) static var flashOverride: Color?

    static func apply(light: Bool, flashHex: String?) {
        isLight = light
        flashOverride = flashHex.flatMap { Color(hex: $0) }
    }

    static func apply(from state: LocationActivityAttributes.ContentState) {
        apply(light: state.lightMode, flashHex: state.flashHex)
    }

    // MARK: Colors
    /// Light mode is a straightforward inversion of the dark values.
    static var background: Color { isLight ? .white : .black }
    /// Primary text (slightly warm off-white on OLED; near-black inverted).
    static var primary: Color {
        isLight ? Color(red: 0.03, green: 0.03, blue: 0.05)
                : Color(red: 0.97, green: 0.97, blue: 0.95)
    }
    /// Secondary / small text.
    static var secondary: Color {
        isLight ? Color(red: 0.26, green: 0.24, blue: 0.20)
                : Color(red: 0.74, green: 0.76, blue: 0.80)
    }
    /// Flash for a value that just changed: pure white (black in light mode),
    /// or the user's custom color when one is set.
    static var flash: Color { flashOverride ?? (isLight ? .black : .white) }
    /// Muted color for the "no signal" state.
    static var muted: Color {
        isLight ? Color(red: 0.45, green: 0.55, blue: 0.70)
                : Color(red: 0.55, green: 0.45, blue: 0.30)
    }

    // MARK: Fonts
    static func font(size: CGFloat, weight: Font.Weight = .regular, family: AppFont = .helvetica) -> Font {
        if let face = family.face(for: weight) {
            return Font.custom(face, size: size)
        }
        return Font.system(size: size, weight: weight, design: .default)
    }

    /// Color for a field, flashing on change.
    static func textColor(changed: Bool, base: Color = primary) -> Color {
        changed ? flash : base
    }
}

// MARK: - Hex color round-trip (custom flash color storage)

extension Color {
    /// "RRGGBB" (with or without leading #).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexString: String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = UIColor(self).cgColor.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              c.count >= 3 else { return nil }
        func byte(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(c[0]), byte(c[1]), byte(c[2]))
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
