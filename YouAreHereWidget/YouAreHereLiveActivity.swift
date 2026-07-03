import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

/// The Live Activity: full layout on the Lock Screen / StandBy, and a compact
/// presentation in the Dynamic Island. Uses the shared `WayfindingView` so the
/// lock screen matches the in-app screen exactly.
struct YouAreHereLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LocationActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            WayfindingView(state: context.state, townSize: 40, alignment: .leading) {
                pauseControl(isPaused: context.state.isPaused, size: 22)
            }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background)
                .activityBackgroundTint(Theme.background)
                .activitySystemActionForegroundColor(Theme.primary)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    if let route = context.state.route {
                        RouteShield(route: route, height: 26,
                                    color: Theme.textColor(changed: context.state.roadChanged, base: Theme.secondary))
                            .padding(.leading, 4)
                    } else {
                        Image(systemName: "road.lanes")
                            .foregroundColor(Theme.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 8) {
                        if let limit = Formatting.speedLimitValue(kmh: context.state.speedLimitKmh,
                                                                  metric: context.state.unitIsMetric) {
                            SpeedLimitSign(value: limit, height: 34,
                                           color: Theme.textColor(changed: context.state.speedLimitChanged, base: Theme.secondary))
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatting.altitudeString(meters: context.state.altitudeMeters,
                                                           metric: context.state.unitIsMetric))
                                .font(Theme.font(size: 13, weight: .medium))
                                .foregroundColor(Theme.secondary)
                            Text(Formatting.headingString(context.state.headingDegrees))
                                .font(Theme.font(size: 13, weight: .medium))
                                .foregroundColor(Theme.textColor(changed: context.state.headingChanged, base: Theme.secondary))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(displayTown(context.state))
                        .font(Theme.font(size: 22, weight: .bold))
                        .foregroundColor(Theme.textColor(changed: context.state.townChanged, base: Theme.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text(roadText(context.state))
                            .font(Theme.font(size: 13, weight: .medium))
                            .foregroundColor(Theme.textColor(changed: context.state.roadChanged, base: Theme.secondary))
                            .lineLimit(1)
                        if !context.state.hasSignal {
                            Image(systemName: "wifi.slash").foregroundColor(Theme.muted).font(.system(size: 11))
                        }
                        Spacer()
                        pauseControl(isPaused: context.state.isPaused, size: 22)
                    }
                }
            } compactLeading: {
                if let route = context.state.route {
                    RouteShield(route: route, height: 20)
                } else {
                    Image(systemName: "location.fill").foregroundColor(Theme.primary)
                }
            } compactTrailing: {
                Text(shortTown(context.state))
                    .font(Theme.font(size: 14, weight: .bold))
                    .foregroundColor(Theme.textColor(changed: context.state.townChanged, base: Theme.primary))
                    .lineLimit(1)
                    .frame(maxWidth: 80)
            } minimal: {
                CompassArrow(degrees: context.state.headingContinuous,
                             size: 16, color: Theme.primary)
            }
            .widgetURL(URL(string: "youarehere://open"))
            .keylineTint(Theme.primary)
        }
    }

    /// Park/resume control. Interactive via an App Intent on iOS 17+; on older
    /// systems it's a non-interactive glyph (tapping the activity opens the app).
    @ViewBuilder
    private func pauseControl(isPaused: Bool, size: CGFloat) -> some View {
        if #available(iOS 17.0, *) {
            Button(intent: TogglePauseIntent()) {
                PauseGlyph(isPaused: isPaused, size: size)
            }
            .buttonStyle(.plain)
        } else {
            PauseGlyph(isPaused: isPaused, size: size)
        }
    }

    private func displayTown(_ s: LocationActivityAttributes.ContentState) -> String {
        s.town.isEmpty ? s.townPlaceholder : s.town
    }

    private func shortTown(_ s: LocationActivityAttributes.ContentState) -> String {
        s.town.isEmpty ? "—" : s.town
    }

    private func roadText(_ s: LocationActivityAttributes.ContentState) -> String {
        if let route = s.route {
            if RouteParser.roadIsJustRoute(road: s.road, route: route) || s.road.isEmpty {
                return Formatting.routeLabel(route)
            }
            return "\(s.road) · \(Formatting.routeLabel(route))"
        }
        return s.road.isEmpty ? "—" : s.road
    }
}
