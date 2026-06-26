import SwiftUI
import AppIntents

/// Lightweight in-process command bus.
///
/// The Live Activity's pause/play button lives in the widget, but a
/// `LiveActivityIntent` runs its `perform()` in the *app's* process (relaunching
/// the app in the background if needed). So the button can reach the running
/// engine through this closure — which the engine installs at startup — without
/// needing a shared app group.
enum LiveActivityActions {
    @MainActor static var togglePause: () -> Void = { }
}

/// Interactive pause/resume button backing for the Live Activity. iOS 17+.
@available(iOS 17.0, *)
struct TogglePauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause or resume location"
    static var description = IntentDescription("Freezes or resumes the live location readout.")

    init() {}

    func perform() async throws -> some IntentResult {
        await MainActor.run { LiveActivityActions.togglePause() }
        return .result()
    }
}

/// The pause/play glyph, shared so the app and Live Activity match exactly.
struct PauseGlyph: View {
    let isPaused: Bool
    var size: CGFloat
    var color: Color = Theme.secondary

    var body: some View {
        Image(systemName: isPaused ? "play.circle.fill" : "pause.circle.fill")
            .font(.system(size: size))
            .foregroundColor(color)
            .accessibilityLabel(isPaused ? "Resume" : "Park")
    }
}
