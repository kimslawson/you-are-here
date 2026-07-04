import AppIntents

/// Zero-config Siri phrases + a Shortcuts action, discovered automatically from
/// the app (no setup in the Shortcuts app required). Every phrase must contain
/// `\(.applicationName)`, so users say e.g. "Where am I in You Are Here." They
/// can rename it to a shorter custom phrase in the Shortcuts app.
struct YouAreHereShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenYouAreHereIntent(),
            phrases: [
                "Where am I in \(.applicationName)",
                "Open \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Where Am I",
            systemImageName: "location.fill"
        )
    }
}
