import SwiftUI

@main
struct YouAreHereApp: App {
    @StateObject private var engine = LocationEngine.shared

    init() {
        // Force the engine to exist at process launch so it installs the Live
        // Activity pause-bus closure — even when iOS cold-launches us in the
        // background solely to run the pause/resume intent.
        _ = LocationEngine.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
