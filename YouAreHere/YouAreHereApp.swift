import SwiftUI

@main
struct YouAreHereApp: App {
    @StateObject private var engine = LocationEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
