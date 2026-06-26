import SwiftUI

/// A north-pointing arrow. It expects a *continuous* angle (see
/// `ContentState.headingContinuous`) that the engine keeps unwrapped so each
/// successive value differs by the shortest signed step. That way the rotation
/// animates the short way across north in BOTH contexts:
///
///   - In the app, the enclosing view's `.animation(value: state)` tweens it.
///   - In the Live Activity / Dynamic Island, ActivityKit tweens between
///     content snapshots. (A per-view `@State` accumulator can't work there —
///     the system re-renders the view fresh for every snapshot — which is why
///     the continuity has to come from the model, not the view.)
struct CompassArrow: View {
    /// Continuous heading angle in degrees (may exceed 360 / go negative).
    let degrees: Double?
    var size: CGFloat
    var color: Color

    var body: some View {
        Image(systemName: "location.north.line.fill")
            .font(.system(size: size))
            .foregroundColor(color)
            .rotationEffect(.degrees(degrees ?? 0))
    }
}
