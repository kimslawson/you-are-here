import SwiftUI

/// The core three-line wayfinding layout, shared by the full-screen app and the
/// lock-screen Live Activity (which just renders it at a smaller scale).
///
///   line 1 (small): road name  ·  [shield] route name
///   line 2 (BIG):   town name
///   line 3 (small): altitude   ·   heading
struct WayfindingView<Trailing: View>: View {
    let state: LocationActivityAttributes.ContentState
    /// Base point size for the big town line. Small lines scale from this.
    var townSize: CGFloat = 64
    var alignment: HorizontalAlignment = .leading
    /// Visual multiplier for the speed-limit sign. Cramped layouts (portrait,
    /// Live Activity) pass 2: the sign renders bigger but keeps its normal
    /// layout footprint, overflowing downward over the town line.
    var speedSignScale: CGFloat = 1
    /// Optional control pinned to the trailing end of the altitude/heading line
    /// (e.g. the park/resume button).
    @ViewBuilder var trailing: () -> Trailing

    private var smallSize: CGFloat { max(12, townSize * 0.27) }
    private var shieldHeight: CGFloat { max(16, townSize * 0.34) }

    private var showSeparateRoad: Bool {
        guard let route = state.route else { return false }
        return !RouteParser.roadIsJustRoute(road: state.road, route: route)
    }

    var body: some View {
        VStack(alignment: alignment, spacing: townSize * 0.06) {
            roadLine
                .zIndex(1)   // the scaled-up speed sign overlaps the town line
            townLine
            metricsLine
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    // MARK: Line 1 — road + route shield
    private var roadLine: some View {
        // Route marker + label share the road's gray color and flash white on change.
        let routeColor = Theme.textColor(changed: state.roadChanged, base: Theme.secondary)
        return HStack(spacing: smallSize * 0.5) {
            if let route = state.route {
                if showSeparateRoad && !state.road.isEmpty {
                    Text(state.road)
                        .font(Theme.font(size: smallSize, weight: .medium))
                        .foregroundColor(routeColor)
                    Text("·")
                        .font(Theme.font(size: smallSize, weight: .medium))
                        .foregroundColor(Theme.secondary)
                }
                RouteShield(route: route, height: shieldHeight, color: routeColor)
                Text(Formatting.routeLabel(route))
                    .font(Theme.font(size: smallSize, weight: .semibold))
                    .foregroundColor(routeColor)
            } else {
                Text(state.road.isEmpty ? "—" : state.road)
                    .font(Theme.font(size: smallSize, weight: .medium))
                    .foregroundColor(Theme.textColor(changed: state.roadChanged, base: Theme.secondary))
            }
            Spacer(minLength: smallSize * 0.5)
            if let limit = Formatting.speedLimitValue(kmh: state.speedLimitKmh, metric: state.unitIsMetric) {
                // Scaled up, the sign keeps its unscaled height in layout and
                // spills below the road line (over the town line's trailing end).
                SpeedLimitSign(value: limit, height: townSize * 0.5 * speedSignScale,
                               color: Theme.textColor(changed: state.speedLimitChanged, base: Theme.secondary))
                    .frame(height: townSize * 0.5, alignment: .top)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    // MARK: Line 2 — town (the headline)
    private var townLine: some View {
        Text(state.town.isEmpty ? state.townPlaceholder : state.town)
            .font(Theme.font(size: townSize, weight: .bold))
            .foregroundColor(Theme.textColor(changed: state.townChanged,
                                             base: state.town.isEmpty ? Theme.muted : Theme.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    // MARK: Line 3 — altitude + heading
    private var metricsLine: some View {
        HStack(spacing: smallSize * 0.6) {
            Label {
                Text(Formatting.altitudeString(meters: state.altitudeMeters, metric: state.unitIsMetric))
                    .font(Theme.font(size: smallSize, weight: .medium))
                    .foregroundColor(Theme.secondary)
            } icon: {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: smallSize * 0.85))
                    .foregroundColor(Theme.secondary)
            }

            Text("·")
                .font(Theme.font(size: smallSize, weight: .medium))
                .foregroundColor(Theme.secondary)

            Label {
                Text(Formatting.headingString(state.headingDegrees))
                    .font(Theme.font(size: smallSize, weight: .medium))
                    .foregroundColor(Theme.textColor(changed: state.headingChanged, base: Theme.secondary))
            } icon: {
                CompassArrow(degrees: state.headingContinuous,
                             size: smallSize * 0.85,
                             color: Theme.textColor(changed: state.headingChanged, base: Theme.secondary))
            }

            if !state.hasSignal {
                Image(systemName: "wifi.slash")
                    .font(.system(size: smallSize * 0.85))
                    .foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// A US-style posted speed-limit sign ("SPEED / LIMIT / nn"), drawn monochrome
/// in `color` so it matches the road text and flashes white on change. The unit
/// (mph vs km/h) follows the app setting; the value is already converted.
struct SpeedLimitSign: View {
    let value: Int
    var height: CGFloat
    var color: Color = Theme.secondary

    var body: some View {
        VStack(spacing: height * 0.015) {
            Text("SPEED").font(Theme.font(size: height * 0.15, weight: .semibold))
            Text("LIMIT").font(Theme.font(size: height * 0.15, weight: .semibold))
            Text("\(value)")
                .font(Theme.font(size: height * 0.42, weight: .bold))
                .padding(.top, height * 0.02)
        }
        .foregroundColor(color)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, height * 0.14)
        .padding(.vertical, height * 0.09)
        .background(
            RoundedRectangle(cornerRadius: height * 0.10)
                .stroke(color, lineWidth: max(1, height * 0.045))
        )
        .fixedSize()
    }
}

// Convenience initializer for callers that don't need a trailing control.
extension WayfindingView where Trailing == EmptyView {
    init(state: LocationActivityAttributes.ContentState,
         townSize: CGFloat = 64,
         alignment: HorizontalAlignment = .leading,
         speedSignScale: CGFloat = 1) {
        self.init(state: state, townSize: townSize, alignment: alignment,
                  speedSignScale: speedSignScale, trailing: { EmptyView() })
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        WayfindingView(state: .placeholder, townSize: 72)
            .padding()
    }
}
