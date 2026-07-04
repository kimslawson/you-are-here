import WidgetKit
import SwiftUI

@main
struct YouAreHereWidgetBundle: WidgetBundle {
    var body: some Widget {
        YouAreHereLiveActivity()
        // Control Center launch button — iOS 18+ only.
        if #available(iOS 18.0, *) {
            LaunchControl()
        }
    }
}
