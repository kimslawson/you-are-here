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
            // Adopt the appearance the app put in the state (this runs in the
            // widget process, which can't read the app's UserDefaults).
            let _ = Theme.apply(from: context.state)
            // Lock Screen / banner presentation.
            ZStack {
                activityBackdrop(context.state)
                WayfindingView(state: context.state, townSize: 40, alignment: .leading,
                               speedSignScale: 2) {
                    pauseControl(isPaused: context.state.isPaused, size: 22)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background)
                .activityBackgroundTint(Theme.background)
                .activitySystemActionForegroundColor(Theme.primary)

        } dynamicIsland: { context in
            Theme.apply(from: context.state)
            return DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    if let route = context.state.route {
                        RouteShield(route: route, height: 26,
                                    color: Theme.textColor(changed: context.state.roadChanged, base: Theme.secondary),
                                    family: context.state.appFont)
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
                                           color: Theme.textColor(changed: context.state.speedLimitChanged, base: Theme.secondary),
                                           family: context.state.appFont)
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatting.altitudeString(meters: context.state.altitudeMeters,
                                                           metric: context.state.unitIsMetric))
                                .font(context.state.font(size: 13, weight: .medium))
                                .foregroundColor(Theme.secondary)
                            Text(Formatting.headingString(context.state.headingDegrees))
                                .font(context.state.font(size: 13, weight: .medium))
                                .foregroundColor(Theme.textColor(changed: context.state.headingChanged, base: Theme.secondary))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(displayTown(context.state))
                        .font(context.state.font(size: 22, weight: .bold))
                        .foregroundColor(Theme.textColor(changed: context.state.townChanged, base: Theme.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        roadContent(context.state)
                        if !context.state.hasSignal {
                            Image(systemName: "wifi.slash").foregroundColor(Theme.muted).font(.system(size: 11))
                        }
                        Spacer()
                        pauseControl(isPaused: context.state.isPaused, size: 22)
                    }
                }
            } compactLeading: {
                if let route = context.state.route {
                    RouteShield(route: route, height: 20, family: context.state.appFont)
                } else {
                    Image(systemName: "location.fill").foregroundColor(Theme.primary)
                }
            } compactTrailing: {
                Text(shortTown(context.state))
                    .font(context.state.font(size: 14, weight: .bold))
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

    /// The aesthetic backdrop, rendered statically — it refreshes whenever the
    /// activity's content does (~1/s while driving). Only the procedural ones:
    /// streets geometry can't fit in the activity's state budget, and neon is
    /// dark-mode only.
    @ViewBuilder
    private func activityBackdrop(_ s: LocationActivityAttributes.ContentState) -> some View {
        let art = BackgroundArt(rawValue: s.backgroundID)
        if art == .topo || (art == .neon && !s.lightMode) {
            Canvas { ctx, size in
                switch art {
                case .topo:
                    let path = BackgroundArtRenderer.topoContours(size: size)
                    BackgroundArtRenderer.drawTopo(&ctx, size: size, path: path, date: Date())
                case .neon:
                    BackgroundArtRenderer.drawNeon(
                        &ctx, size: size,
                        phase: BackgroundArtRenderer.neonAutoPhase(at: Date()))
                default:
                    break
                }
            }
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

    /// Road + optional route label, joined by the drawn dot (the "·" character
    /// is an empty glyph in some bundled fonts — see SeparatorDot).
    @ViewBuilder
    private func roadContent(_ s: LocationActivityAttributes.ContentState) -> some View {
        let color = Theme.textColor(changed: s.roadChanged, base: Theme.secondary)
        if let route = s.route,
           !RouteParser.roadIsJustRoute(road: s.road, route: route), !s.road.isEmpty {
            Text(s.road)
                .font(s.font(size: 13, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
            SeparatorDot(size: 13)
            Text(Formatting.routeLabel(route))
                .font(s.font(size: 13, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
        } else {
            Text(roadText(s))
                .font(s.font(size: 13, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
        }
    }

    private func roadText(_ s: LocationActivityAttributes.ContentState) -> String {
        if let route = s.route {
            // Separate road + route is handled by roadContent; here the route
            // IS the road (or the road is unknown).
            return Formatting.routeLabel(route)
        }
        return s.road.isEmpty ? "—" : s.road
    }
}
