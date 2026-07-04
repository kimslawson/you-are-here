import AppIntents

/// Brings the app to the foreground. Launching is all that's needed to "start"
/// a session — `ContentView.onAppear` requests authorization, starts the
/// engine, and kicks off the Live Activity. Backs both the Siri phrase / App
/// Shortcut and the iOS 18 Control Center button, so it lives in Shared (like
/// `TogglePauseIntent`) to compile into both the app and the widget extension.
struct OpenYouAreHereIntent: AppIntent {
    static var title: LocalizedStringResource = "Open You Are Here"
    static var description = IntentDescription("Opens the live location readout and starts the Live Activity.")
    /// Foreground the app when run — the reliable way to spin up the live
    /// session and its Live Activity from a cold or backgrounded state.
    static var openAppWhenRun = true

    init() {}

    func perform() async throws -> some IntentResult {
        .result()
    }
}
