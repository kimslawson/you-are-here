import SwiftUI

/// A compact, recognizable highway shield drawn with SwiftUI shapes (no image
/// assets needed). Stylized rather than pixel-accurate to the MUTCD, but the
/// colors and silhouettes read correctly at a glance:
///   - Interstate: red/blue shield
///   - US highway: white rounded shield with black number
///   - State highway: white rounded square / circle with black number
struct RouteShield: View {
    let route: RouteRef
    var height: CGFloat = 22

    private var label: String {
        switch route.kind {
        case .interstate, .usHighway:
            return route.number
        case .stateHighway:
            if let a = route.stateAbbrev, !a.isEmpty { return "\(a) \(route.number)" }
            return route.number
        }
    }

    var body: some View {
        switch route.kind {
        case .interstate: interstate
        case .usHighway:  usHighway
        case .stateHighway: stateHighway
        }
    }

    private var numberFont: Font {
        Theme.font(size: height * 0.52, weight: .bold)
    }

    // Interstate: blue shield body, red top banner.
    private var interstate: some View {
        ZStack {
            ShieldShape()
                .fill(Color(red: 0.04, green: 0.16, blue: 0.45)) // interstate blue
            ShieldShape()
                .trim(from: 0, to: 1)
                .stroke(Color.white, lineWidth: 1)
            VStack(spacing: 0) {
                Color(red: 0.78, green: 0.10, blue: 0.16) // interstate red
                    .frame(height: height * 0.26)
                Spacer(minLength: 0)
            }
            .mask(ShieldShape())
            Text(route.number)
                .font(numberFont)
                .foregroundColor(.white)
                .padding(.top, height * 0.12)
                .minimumScaleFactor(0.5)
        }
        .frame(width: height * 0.92, height: height)
    }

    // US highway: white rounded shield, black number.
    private var usHighway: some View {
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.22)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: height * 0.22)
                .stroke(Color.black, lineWidth: 1)
            Text(route.number)
                .font(numberFont)
                .foregroundColor(.black)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 3)
        }
        .frame(minWidth: height * 0.92, idealWidth: height, maxWidth: height * 1.6, maxHeight: height)
        .fixedSize()
    }

    // State highway: white square with black number (+ abbrev if present).
    private var stateHighway: some View {
        ZStack {
            RoundedRectangle(cornerRadius: height * 0.16)
                .fill(Color.white)
            RoundedRectangle(cornerRadius: height * 0.16)
                .stroke(Color.black, lineWidth: 1)
            Text(label)
                .font(Theme.font(size: height * 0.46, weight: .bold))
                .foregroundColor(.black)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
        }
        .frame(minWidth: height * 0.92, maxWidth: height * 1.8, maxHeight: height)
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
        RouteShield(route: RouteRef(kind: .interstate, number: "80", stateAbbrev: nil), height: 36)
        RouteShield(route: RouteRef(kind: .usHighway, number: "50", stateAbbrev: nil), height: 36)
        RouteShield(route: RouteRef(kind: .stateHighway, number: "89", stateAbbrev: "CA"), height: 36)
    }
    .padding()
    .background(Color.black)
}
