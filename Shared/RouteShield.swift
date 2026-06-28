import SwiftUI

/// A compact route marker drawn with SwiftUI shapes (no image assets). It's
/// monochrome — rendered in whatever `color` the caller passes so it matches the
/// adjacent road text (gray normally, flashing white on change).
///
/// The interstate keeps its distinctive shield silhouette and shows the number
/// (the number *is* the recognizable interstate marker). The generic box
/// markers (US / state) show only the **region** — "US", or the state abbrev
/// like "ME" — because the full designation ("US-50", "ME-73") already appears
/// as text right next to the marker, so repeating the number would be redundant.
struct RouteShield: View {
    let route: RouteRef
    var height: CGFloat = 22
    var color: Color = Theme.primary

    /// What goes inside the marker.
    private var inner: String {
        switch route.kind {
        case .interstate:
            return route.number
        case .usHighway:
            return "US"
        case .stateHighway:
            if let a = route.stateAbbrev, !a.isEmpty { return a }
            return route.number   // fall back to the number when region unknown
        }
    }

    private var lineWidth: CGFloat { max(1, height * 0.07) }

    var body: some View {
        switch route.kind {
        case .interstate: interstate
        default:          box
        }
    }

    // Interstate: shield silhouette outline + number.
    private var interstate: some View {
        ZStack {
            ShieldShape().stroke(color, lineWidth: lineWidth)
            Text(inner)
                .font(Theme.font(size: height * 0.5, weight: .bold))
                .foregroundColor(color)
                .padding(.top, height * 0.06)
                .minimumScaleFactor(0.5)
        }
        .frame(width: height * 0.94, height: height)
    }

    // US / state: rounded-rect outline hugging the region text.
    private var box: some View {
        Text(inner)
            .font(Theme.font(size: height * 0.46, weight: .bold))
            .foregroundColor(color)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, height * 0.22)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: height * 0.20)
                    .stroke(color, lineWidth: lineWidth)
            )
            .fixedSize()
    }
}

/// A simple interstate-style shield silhouette.
private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addCurve(to: CGPoint(x: w, y: h * 0.28),
                   control1: CGPoint(x: w * 0.82, y: 0),
                   control2: CGPoint(x: w, y: h * 0.10))
        p.addLine(to: CGPoint(x: w, y: h * 0.42))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h),
                   control1: CGPoint(x: w, y: h * 0.74),
                   control2: CGPoint(x: w * 0.72, y: h))
        p.addCurve(to: CGPoint(x: 0, y: h * 0.42),
                   control1: CGPoint(x: w * 0.28, y: h),
                   control2: CGPoint(x: 0, y: h * 0.74))
        p.addLine(to: CGPoint(x: 0, y: h * 0.28))
        p.addCurve(to: CGPoint(x: w * 0.5, y: 0),
                   control1: CGPoint(x: 0, y: h * 0.10),
                   control2: CGPoint(x: w * 0.18, y: 0))
        p.closeSubpath()
        return p
    }
}

#Preview {
    HStack(spacing: 12) {
        RouteShield(route: RouteRef(kind: .interstate, number: "80", stateAbbrev: nil), height: 36, color: Theme.secondary)
        RouteShield(route: RouteRef(kind: .usHighway, number: "50", stateAbbrev: nil), height: 36, color: Theme.secondary)
        RouteShield(route: RouteRef(kind: .stateHighway, number: "73", stateAbbrev: "ME"), height: 36, color: Theme.secondary)
    }
    .padding()
    .background(Color.black)
}
