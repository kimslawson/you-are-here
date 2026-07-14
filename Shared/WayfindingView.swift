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
    /// Extra scale for the small lines (road/route + altitude/heading) relative
    /// to their townSize-derived default. The PiP strip bumps this above 1 so
    /// secondary type stays legible at video-frame sizes.
    var smallScale: CGFloat = 1
    /// Clock the time complication reads. nil means "now" (the live default);
    /// the app passes a past timestamp while scrubbing the Slope trail so the
    /// time retraces along with the rest of the readout.
    var displayDate: Date? = nil
    /// Route view only: drop the big town headline and use a single uniformly
    /// scaled top line (road · route · town) pinned to the top edge, with the
    /// metrics line at the bottom edge — freeing the center for the route trace.
    var edgeAligned: Bool = false
    /// Route view only: a control on the trailing end of the top line (the
    /// settings gear), mirroring `trailing` on the metrics line.
    var topTrailing: AnyView? = nil
    /// Optional control pinned to the trailing end of the altitude/heading line
    /// (e.g. the park/resume button).
    @ViewBuilder var trailing: () -> Trailing

    private var smallSize: CGFloat { max(12, townSize * 0.27 * smallScale) }
    private var shieldHeight: CGFloat { max(16, townSize * 0.34 * smallScale) }

    private var showSeparateRoad: Bool {
        guard let route = state.route else { return false }
        return !RouteParser.roadIsJustRoute(road: state.road, route: route)
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    @ViewBuilder
    private var content: some View {
        if edgeAligned {
            // Road (+ town) at the top edge, metrics at the bottom, route in
            // between. Fills the height it's given so the Spacer can push them apart.
            VStack(alignment: alignment, spacing: 0) {
                routeTopLine
                speedSignBelow
                Spacer(minLength: 0)
                metricsLine
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(alignment: alignment, spacing: townSize * 0.06) {
                roadLine
                    .zIndex(1)   // the scaled-up speed sign overlaps the town line
                townLine
                metricsLine
            }
        }
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
                        .font(state.font(size: smallSize, weight: .medium))
                        .foregroundColor(routeColor)
                    SeparatorDot(size: smallSize)
                }
                RouteShield(route: route, height: shieldHeight, color: routeColor,
                            family: state.appFont)
                Text(Formatting.routeLabel(route))
                    .font(state.font(size: smallSize, weight: .semibold))
                    .foregroundColor(routeColor)
            } else {
                Text(state.road.isEmpty ? "—" : state.road)
                    .font(state.font(size: smallSize, weight: .medium))
                    .foregroundColor(Theme.textColor(changed: state.roadChanged, base: Theme.secondary))
            }
            Spacer(minLength: smallSize * 0.5)
            // Edge-aligned (Route) uses `routeTopLine` instead of this, and drops
            // the sign onto its own row below — see `speedSignBelow`.
            if !edgeAligned,
               let limit = Formatting.speedLimitValue(kmh: state.speedLimitKmh, metric: state.unitIsMetric) {
                // Scaled up, the sign keeps its unscaled height in layout and
                // spills below the road line (over the town line's trailing end).
                SpeedLimitSign(value: limit, height: townSize * 0.5 * speedSignScale,
                               color: Theme.textColor(changed: state.speedLimitChanged, base: Theme.secondary),
                               family: state.appFont)
                    .frame(height: townSize * 0.5, alignment: .top)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // Optical alignment: the small type's left sidebearing sits a touch
        // further out than the big town line's — tuck the road line in a bit.
        .padding(.leading, smallSize * 0.1)
    }

    // MARK: Route top line (road · route · town, one size, never truncated)

    /// The Route view's top line: road, route shield + label, and town, all at a
    /// single font size chosen (via ViewThatFits) so the whole row fits without
    /// truncating any field, with the settings gear on the trailing end — the
    /// mirror of the metrics line's pause control.
    private var routeTopLine: some View {
        HStack(spacing: smallSize * 0.5) {
            ViewThatFits(in: .horizontal) {
                ForEach([1.0, 0.9, 0.8, 0.72, 0.64, 0.56, 0.5, 0.44, 0.38, 0.32], id: \.self) { scale in
                    topLineRow(size: smallSize * CGFloat(scale))
                }
            }
            Spacer(minLength: smallSize * 0.4)
            if let topTrailing { topTrailing }
        }
        .padding(.leading, smallSize * 0.1)
    }

    private func topLineRow(size: CGFloat) -> some View {
        let routeColor = Theme.textColor(changed: state.roadChanged, base: Theme.secondary)
        return HStack(spacing: size * 0.5) {
            if let route = state.route {
                if showSeparateRoad && !state.road.isEmpty {
                    Text(state.road)
                        .font(state.font(size: size, weight: .medium))
                        .foregroundColor(routeColor)
                    SeparatorDot(size: size)
                }
                RouteShield(route: route, height: size * 1.26, color: routeColor,
                            family: state.appFont)
                Text(Formatting.routeLabel(route))
                    .font(state.font(size: size, weight: .semibold))
                    .foregroundColor(routeColor)
            } else {
                Text(state.road.isEmpty ? "—" : state.road)
                    .font(state.font(size: size, weight: .medium))
                    .foregroundColor(routeColor)
            }
            SeparatorDot(size: size)
            Text(state.town.isEmpty ? state.townPlaceholder : state.town)
                .font(state.font(size: size, weight: .medium))
                .foregroundColor(Theme.textColor(changed: state.townChanged, base: Theme.secondary))
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)   // measure/render at natural width
    }

    /// Route view: the speed-limit sign on its own row just below the top line,
    /// pushed to the trailing edge, so the road/route/town text above keeps the
    /// full width. Empty (no space) when there's no posted limit.
    @ViewBuilder
    private var speedSignBelow: some View {
        if let limit = Formatting.speedLimitValue(kmh: state.speedLimitKmh, metric: state.unitIsMetric) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                SpeedLimitSign(value: limit, height: townSize * 0.5 * speedSignScale,
                               color: Theme.textColor(changed: state.speedLimitChanged, base: Theme.secondary),
                               family: state.appFont)
            }
            .padding(.top, smallSize * 0.35)
        }
    }

    /// Width the scaled-up speed sign overflows into the town line. Reserved as
    /// trailing padding so long names scale down to clear it instead of running
    /// underneath (the sign draws ~0.75× as wide as its visual height, plus a
    /// small gap). Zero when there's no sign or no overflow (landscape).
    private var townTrailingReserve: CGFloat {
        guard speedSignScale > 1,
              Formatting.speedLimitValue(kmh: state.speedLimitKmh, metric: state.unitIsMetric) != nil
        else { return 0 }
        return townSize * 0.5 * speedSignScale * 0.75 + smallSize * 0.5
    }

    // MARK: Line 2 — town (the headline)
    private var townLine: some View {
        Text(state.town.isEmpty ? state.townPlaceholder : state.town)
            .font(state.font(size: townSize, weight: .bold))
            .foregroundColor(Theme.textColor(changed: state.townChanged,
                                             base: state.town.isEmpty ? Theme.muted : Theme.primary))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .padding(.trailing, townTrailingReserve)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            // Optical centering: the font's line box reserves headroom above cap
            // height (diacritics) that a title-case name never fills, so metric
            // centering leaves extra air on top. Nudge the visible mass up a bit;
            // pure visual shift, so descenders keep their room below. The amount
            // is per-family — vertical metrics differ (AppFont.townOffsetFactor).
            .offset(y: townSize * state.appFont.townOffsetFactor)
    }

    // MARK: Line 3 — optional complications (dot-separated) + trailing control.
    // With none chosen the row is empty but keeps its height (the trailing
    // control holds it), so the town/road lines above don't move.
    //
    // The whole complications block scales as ONE unit (ViewThatFits picks the
    // largest candidate scale that fits), so every value shares a single font
    // size and nothing ever truncates. Each candidate is *measured* against
    // widest-template strings (every digit an "8", two-letter cardinal,
    // two-digit hour) rather than the live values, so the chosen scale holds
    // steady while values tick once a second instead of re-zooming per update.
    private var metricsLine: some View {
        HStack(spacing: smallSize * 0.6) {
            ViewThatFits(in: .horizontal) {
                ForEach([1.0, 0.9, 0.8, 0.72, 0.64, 0.56, 0.48, 0.42], id: \.self) { scale in
                    complicationsRow(scale: CGFloat(scale))
                }
            }
            if !state.hasSignal {
                Image(systemName: "wifi.slash")
                    .font(.system(size: smallSize * 0.85))
                    .foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }

    private func complicationsRow(scale: CGFloat) -> some View {
        let size = smallSize * scale
        // The invisible sizing row fixes the footprint; the live row renders on
        // top, leading-aligned, always at or under the template width.
        return ZStack(alignment: .leading) {
            rowContent(size: size, sizing: true).opacity(0)
            rowContent(size: size, sizing: false)
        }
        .fixedSize(horizontal: true, vertical: false)   // measure/render at natural width
    }

    private func rowContent(size: CGFloat, sizing: Bool) -> some View {
        let comps = Complication.decode(state.complications)
        return HStack(spacing: size * 0.7) {
            ForEach(Array(comps.enumerated()), id: \.offset) { index, comp in
                if index > 0 { SeparatorDot(size: size) }
                complication(comp, size: size, sizing: sizing)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func complication(_ c: Complication, size: CGFloat, sizing: Bool) -> some View {
        switch c {
        case .altitude:
            // Altitude and compass keep their icons; time and temperature are
            // text-only to leave room and stay uniform.
            let text = Formatting.altitudeString(meters: state.altitudeMeters,
                                                 metric: state.unitIsMetric)
            Label {
                complicationText(sizing ? eights(text) : text, color: Theme.secondary, size: size)
            } icon: {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: size * 0.85))
                    .foregroundColor(Theme.secondary)
            }
        case .compass:
            let color = Theme.textColor(changed: state.headingChanged, base: Theme.secondary)
            Label {
                complicationText(sizing ? (state.headingDegrees == nil ? "—" : "WW 888°")
                                        : Formatting.headingString(state.headingDegrees),
                                 color: color, size: size)
            } icon: {
                CompassArrow(degrees: state.headingContinuous, size: size * 0.85, color: color)
            }
        case .time:
            complicationText(sizing ? (state.clock24 ? "88:88" : "88:88 PM")
                                    : Formatting.timeString(displayDate ?? Date(), clock24: state.clock24),
                             color: Theme.textColor(changed: state.timeChanged, base: Theme.secondary),
                             size: size)
        case .temperature:
            let text = Formatting.temperatureString(celsius: state.temperatureC,
                                                    metric: state.unitIsCelsius)
            complicationText(sizing ? eights(text) : text,
                             color: Theme.textColor(changed: state.temperatureChanged, base: Theme.secondary),
                             size: size)
        }
    }

    /// Digits → "8" (typically the widest digit), so a template keeps a value's
    /// width stable while the value ticks. Width still moves when the digit
    /// *count* changes (999 → 1,000 ft) — a real rescale, and rare.
    private func eights(_ s: String) -> String {
        String(s.map { $0.isNumber ? "8" : $0 })
    }

    private func complicationText(_ text: String, color: Color, size: CGFloat) -> some View {
        Text(text)
            .font(state.font(size: size, weight: .medium))
            .foregroundColor(color)
    }
}

/// Font-agnostic replacement for the "·" separator character: some bundled
/// faces ship an *empty* middle-dot glyph (Overpass's static builds, for one),
/// which renders as a silent gap. A drawn circle can't go missing.
struct SeparatorDot: View {
    /// Point size of the adjacent text; the dot scales from it.
    var size: CGFloat
    var color: Color = Theme.secondary

    var body: some View {
        // Chunkier than a typographic middot (~0.11em): drawn in isolation it
        // needs more mass to read as intentional, and a floor keeps it from
        // shrinking to dust at Live Activity / Dynamic Island sizes.
        let diameter = max(2.5, size * 0.2)
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
    }
}

/// A US-style posted speed-limit sign ("SPEED / LIMIT / nn"), drawn monochrome
/// in `color` so it matches the road text and flashes white on change. The unit
/// (mph vs km/h) follows the app setting; the value is already converted.
struct SpeedLimitSign: View {
    let value: Int
    var height: CGFloat
    var color: Color = Theme.secondary
    var family: AppFont = .helvetica

    var body: some View {
        VStack(spacing: height * 0.015) {
            Text("SPEED").font(Theme.font(size: height * 0.15, weight: .semibold, family: family))
            Text("LIMIT").font(Theme.font(size: height * 0.15, weight: .semibold, family: family))
            Text("\(value)")
                .font(Theme.font(size: height * 0.42, weight: .bold, family: family))
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
         speedSignScale: CGFloat = 1,
         smallScale: CGFloat = 1,
         edgeAligned: Bool = false) {
        self.init(state: state, townSize: townSize, alignment: alignment,
                  speedSignScale: speedSignScale, smallScale: smallScale,
                  edgeAligned: edgeAligned,
                  trailing: { EmptyView() })
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        WayfindingView(state: .placeholder, townSize: 72)
            .padding()
    }
}
