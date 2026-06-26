import SwiftUI

/// A north-pointing arrow that rotates the *short way* around.
///
/// Feeding `rotationEffect` the raw 0–359° heading makes SwiftUI spin the long
/// way when the value wraps (e.g. 350° → 10° animates −340° instead of +20°).
/// We instead keep a continuous, accumulating angle and advance it by the
/// shortest signed delta each update, so it always animates smoothly across N.
struct CompassArrow: View {
    let degrees: Double?
    var size: CGFloat
    var color: Color

    /// Continuous angle (may exceed 360 / go negative); only the visual matters.
    @State private var displayed: Double = 0
    @State private var hasValue = false

    var body: some View {
        Image(systemName: "location.north.line.fill")
            .font(.system(size: size))
            .foregroundColor(color)
            .rotationEffect(.degrees(displayed))
            .onAppear { sync(animated: false) }
            .onChange(of: degrees) { _ in sync(animated: true) }
    }

    private func sync(animated: Bool) {
        guard let target = degrees else { return }
        let next: Double
        if hasValue {
            // Shortest signed step into (-180, 180].
            var delta = (target - displayed).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            next = displayed + delta
        } else {
            next = target
        }
        hasValue = true
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { displayed = next }
        } else {
            displayed = next
        }
    }
}
