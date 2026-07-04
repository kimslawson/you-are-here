import Foundation
import CoreLocation

/// UserDefaults keys shared between the app UI (via @AppStorage) and the engine.
enum SettingsKey {
    static let unitIsMetric = "unitIsMetric"
    static let liveActivityEnabled = "liveActivityEnabled"
    static let refreshSeconds = "refreshSeconds"
    static let onlineRouteLookup = "onlineRouteLookup"
    static let showSpeedLimit = "showSpeedLimit"
    static let pictureInPicture = "pictureInPicture"
    static let pipLargeWindow = "pipLargeWindow"
    static let appFont = "appFont"
    static let lightMode = "lightMode"
    static let backgroundArt = "backgroundArt"
    static let customFlashColor = "customFlashColor"
    static let flashColorHex = "flashColorHex"
    /// The font in use before the Easter egg switched to Comic, for the way back.
    static let preComicFont = "preComicFont"
}

extension AppFont {
    /// The user's chosen typeface. Lives here (app target) because only the app
    /// process reads UserDefaults — the widget gets the choice via ContentState.
    static func current(_ defaults: UserDefaults = .standard) -> AppFont {
        defaults.string(forKey: SettingsKey.appFont).flatMap(AppFont.init(rawValue:)) ?? .helvetica
    }
}

extension UserDefaults {
    var unitIsMetric: Bool { bool(forKey: SettingsKey.unitIsMetric) }
}

/// How often the readout refreshes — and, coupled to it, how hard the GPS radio
/// works. Slower rates relax accuracy and the distance/heading filters so the
/// receiver can power down between fixes (the real battery/heat lever), at the
/// cost of coarser altitude and town/road snapping at 5s/10s.
enum RefreshRate: Int, CaseIterable, Identifiable {
    case s1 = 1
    case s2 = 2
    case s5 = 5
    case s10 = 10

    var id: Int { rawValue }
    var interval: TimeInterval { Double(rawValue) }

    var label: String {
        switch self {
        case .s1:  return "1s"
        case .s2:  return "2s"
        case .s5:  return "5s"
        case .s10: return "10s"
        }
    }

    var desiredAccuracy: CLLocationAccuracy {
        switch self {
        case .s1, .s2: return kCLLocationAccuracyBest
        case .s5:      return kCLLocationAccuracyNearestTenMeters
        case .s10:     return kCLLocationAccuracyHundredMeters
        }
    }

    var distanceFilter: CLLocationDistance {
        switch self {
        case .s1:  return kCLDistanceFilterNone
        case .s2:  return 5
        case .s5:  return 10
        case .s10: return 25
        }
    }

    var headingFilter: CLLocationDegrees {
        switch self {
        case .s1:  return 1
        case .s2:  return 2
        case .s5:  return 3
        case .s10: return 5
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> RefreshRate {
        RefreshRate(rawValue: defaults.integer(forKey: SettingsKey.refreshSeconds)) ?? .s1
    }
}
