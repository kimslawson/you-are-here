import SwiftUI

@main
struct YouAreHereApp: App {
    @StateObject private var engine = LocationEngine.shared
    @AppStorage(SettingsKey.lightMode) private var lightMode = false

    init() {
        // Force the engine to exist at process launch so it installs the Live
        // Activity pause-bus closure — even when iOS cold-launches us in the
        // background solely to run the pause/resume intent.
        _ = LocationEngine.shared

        #if METRICS_LOGGING
        // Register the MetricKit subscriber early so it's live before iOS
        // delivers any pending daily payload (see README ▸ Debugging).
        MetricsLogger.shared.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(lightMode ? .light : .dark)
                .statusBarHidden(true)
        }
    }
}
