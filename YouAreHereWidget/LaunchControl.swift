import WidgetKit
import SwiftUI
import AppIntents

/// A Control Center button (iOS 18+) that opens the app — one tap from the
/// pulled-down Control Center to start a live session, no home-screen hunting.
/// Added to the widget bundle behind an availability check.
@available(iOS 18.0, *)
struct LaunchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.kimslawson.YouAreHere.launch") {
            ControlWidgetButton(action: OpenYouAreHereIntent()) {
                Label("You Are Here", systemImage: "location.fill")
            }
        }
        .displayName("You Are Here")
        .description("Open the live location readout.")
    }
}
