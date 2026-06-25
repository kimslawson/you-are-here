import SwiftUI

/// Central place for the wayfinding look: a grotesque sans, bright-on-dark
/// palette, and the white "flash" used when a field changes.
///
/// Font: iOS ships Helvetica Neue, a true neo-grotesque in the lineage of
/// transit/road signage (Highway Gothic, Helvetica on the NYC subway). It reads
/// cleanly at a glance, which is exactly the wayfinding feel we want. Swap the
/// `family` constant if you'd rather use the system font (SF Pro).
enum Theme {

    /// Set to `nil` to fall back to the system font (SF Pro).
    static let family: String? = "HelveticaNeue"

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
    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let family {
            // Map weight to a concrete Helvetica Neue face name.
            let face: String
            switch weight {
            case .bold, .heavy, .black: face = "\(family)-Bold"
            case .semibold:             face = "\(family)-Medium"
            case .medium:               face = "\(family)-Medium"
            case .light, .thin:         face = "\(family)-Light"
            default:                    face = family
            }
            return Font.custom(face, size: size)
        } else {
            return Font.system(size: size, weight: weight, design: .default)
        }
    }

    /// Color for a field, flashing white on change.
    static func textColor(changed: Bool, base: Color = primary) -> Color {
        changed ? flash : base
    }
}
