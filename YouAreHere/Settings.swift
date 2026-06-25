import Foundation

/// UserDefaults keys shared between the app UI (via @AppStorage) and the engine.
enum SettingsKey {
    static let unitIsMetric = "unitIsMetric"
    static let liveActivityEnabled = "liveActivityEnabled"
}

extension UserDefaults {
    var unitIsMetric: Bool { bool(forKey: SettingsKey.unitIsMetric) }
}
