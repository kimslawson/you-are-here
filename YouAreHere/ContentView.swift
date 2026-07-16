import SwiftUI
import CoreLocation

/// Full-screen version of the widget: the same three lines, using the whole
/// display. Keeps the screen awake so it can ride on the dashboard.
struct ContentView: View {
    @EnvironmentObject private var engine: LocationEngine
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.unitIsMetric) private var unitIsMetric = false
    @AppStorage(SettingsKey.pictureInPicture) private var pictureInPicture = false
    @AppStorage(SettingsKey.pipLargeWindow) private var pipLargeWindow = false
    @AppStorage(SettingsKey.backgroundArt) private var backgroundArt = BackgroundArt.off.rawValue
    @StateObject private var pip = PiPManager()
    @State private var showSettings = false
    /// The control bezel (Settings / Share / Routes) is hidden until a tap
    /// anywhere summons it; it fades back out after a few seconds.
    @State private var chromeVisible = false
    @State private var chromeHideTask: Task<Void, Never>?
    // Easter egg: 10 quick taps swap to Comic; 10 more swap back.
    @State private var eggTaps = 0
    @State private var lastEggTap = Date.distantPast
    // Slope / Route backgrounds: the scrubbed playhead on the trail's
    // active-time axis (nil = live), plus the drag's anchor captured at gesture
    // start. Meaningful only for those two.
    @State private var slopeSelected: TimeInterval?
    @State private var slopeDragAnchor: TimeInterval?
    // True after the edge haptic fired, until the playhead leaves the edge (or
    // the drag ends) — one bump per arrival, not one per drag update.
    @State private var scrubEdgeLatched = false
    // Route background: pinch-zoom factor (1 = whole route fit), and the value
    // committed at the last pinch's end (the base the live gesture multiplies).
    @State private var routeZoom: CGFloat = 1
    @State private var routeZoomBase: CGFloat = 1
    // Set once the engine has started, so the "Stopped" screen only shows after
    // an explicit Stop — not during the first frame before start() runs.
    @State private var didStart = false
    // Playback: a saved route loaded from the Routes list. While set, the
    // Slope/Route backgrounds, scrubbing, and the retraced readout all use it
    // instead of the live trail; the snap-to-present control exits back to live.
    @State private var playback: TrackLog?
    @State private var showRoutes = false
    @State private var showShareOptions = false
    @State private var shareItem: ShareItem?

    /// The trail everything trail-driven reads: the playback route if one is
    /// loaded, else the live recording.
    private var activeTrack: TrackLog { playback ?? engine.track }

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height >= geo.size.width
            // Route clears the center for the map: the top line hugs the top edge
            // (with the gear inline on it) and metrics the bottom.
            let routeLayout = BackgroundArt(rawValue: backgroundArt) == .route
            ZStack {
                Theme.background.ignoresSafeArea()

                // A E S T H E T I C : the optional barely-there backdrop.
                // Neon is dark-mode only — dim glow lines have nothing to
                // glow against on white.
                if !needsPermission,
                   let art = BackgroundArt(rawValue: backgroundArt), art != .off,
                   !(art == .neon && engine.state.lightMode) {
                    BackgroundArtView(kind: art, track: activeTrack,
                                      slopeSelected: slopeSelected, routeZoom: routeZoom)
                }

                // Offscreen-ish host for the PiP video layer (must be in the
                // hierarchy for AVKit to float it).
                PiPHostView(manager: pip)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if needsPermission {
                    permissionPrompt
                } else if didStart && !engine.isRunning {
                    stoppedView
                } else {
                    // Live, or — while scrubbing a Slope/Route trail — the readout
                    // recorded at the playhead moment.
                    let scrub = scrubbedReadout()
                    WayfindingView(state: scrub.state,
                                   townSize: townSize(for: geo.size),
                                   alignment: .leading,
                                   // Portrait is cramped; double the speed sign.
                                   speedSignScale: isPortrait ? 2 : 1,
                                   displayDate: scrub.displayDate,
                                   edgeAligned: routeLayout) {
                        HStack(spacing: townSize(for: geo.size) * 0.16) {
                            // Scrubbed into the past, it's easy to stop just shy
                            // of "now" and think the graph is stuck — surface a
                            // one-tap way back to the present. Only shown while
                            // scrubbed (or playing back a saved route), so it
                            // doubles as the "not live" indicator.
                            if slopeSelected != nil || playback != nil {
                                Button {
                                    slopeSelected = nil
                                    slopeDragAnchor = nil
                                    playback = nil
                                } label: {
                                    Image(systemName: "arrow.uturn.forward.circle.fill")
                                        .font(.system(size: townSize(for: geo.size) * 0.32))
                                        .foregroundColor(Theme.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Back to now")
                            }
                            Button {
                                engine.togglePause()
                            } label: {
                                PauseGlyph(isPaused: engine.isPaused, size: townSize(for: geo.size) * 0.32)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, routeLayout ? 12 : 0)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    .animation(.easeOut(duration: 0.25), value: engine.state)
                }

                // Control bezel: tap anywhere to summon Settings / Share /
                // Routes, bottom-center where thumbs live; it fades out after a
                // few seconds. No persistent chrome — the readout owns the screen.
                if chromeVisible {
                    VStack {
                        Spacer()
                        HStack(alignment: .top, spacing: 26) {
                            bezelControl("Settings", icon: "gearshape") { showSettings = true }
                            bezelControl("Share", icon: "square.and.arrow.up") { showShareOptions = true }
                            bezelControl("Routes", icon: "list.bullet") { showRoutes = true }
                        }
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial,
                                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.bottom, 16)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                revealChrome()
                registerEggTap()
            }
            .gesture(scrubDrag(width: geo.size.width))
            .simultaneousGesture(routePinch())
            .confirmationDialog("Share", isPresented: $showShareOptions, titleVisibility: .visible) {
                Button("Current view as image") { shareImage(size: geo.size) }
                Button("Route data (JSON)") { shareJSON() }
            }
        }
        .onAppear {
            // Keep awake on the dash while live; allow sleep when parked.
            UIApplication.shared.isIdleTimerDisabled = !engine.isPaused
            engine.requestAuthorization()
            engine.start()
            didStart = true
            pip.bind(to: engine)
            pip.setEnabled(pictureInPicture)
        }
        .onChange(of: engine.isPaused) { paused in
            UIApplication.shared.isIdleTimerDisabled = engine.isRunning && !paused
        }
        .onChange(of: engine.isRunning) { running in
            // Stopped: let the screen sleep again.
            UIApplication.shared.isIdleTimerDisabled = running && !engine.isPaused
        }
        .onChange(of: pictureInPicture) { enabled in
            pip.setEnabled(enabled)
        }
        .onChange(of: backgroundArt) { _ in
            // Switching background drops any scrub/zoom, so the next visit starts
            // live and fit-to-view.
            slopeSelected = nil
            slopeDragAnchor = nil
            routeZoom = 1
            routeZoomBase = 1
        }
        .onChange(of: pipLargeWindow) { _ in
            // Next frame carries the new canvas; the window animates to match.
            pip.redraw()
        }
        .onChange(of: scenePhase) { phase in
            // Back in the foreground (app icon, Live Activity tap, PiP restore
            // button): the full app is showing, so the floating window is
            // redundant — dismiss it.
            if phase == .active { pip.dismissForForeground() }
            // Leaving: persist the drive so it shows in the Routes list even if
            // the process never comes back.
            if phase == .background { engine.saveTrack() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .preferredColorScheme(engine.state.lightMode ? .light : .dark)
        }
        .sheet(isPresented: $showRoutes) {
            RoutesListView { route in startPlayback(route) }
                .preferredColorScheme(engine.state.lightMode ? .light : .dark)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.items)
        }
    }

    /// Easter egg: 10 quick taps (≤2s apart) on the screen switch the font to
    /// Comic; 10 more switch back to whatever was active before.
    private func registerEggTap() {
        let now = Date()
        if now.timeIntervalSince(lastEggTap) > 2 { eggTaps = 0 }
        lastEggTap = now
        eggTaps += 1
        guard eggTaps >= 10 else { return }
        eggTaps = 0

        let defaults = UserDefaults.standard
        if AppFont.current() == .comic {
            let previous = defaults.string(forKey: SettingsKey.preComicFont)
                ?? AppFont.helvetica.rawValue
            defaults.set(previous, forKey: SettingsKey.appFont)
        } else {
            defaults.set(AppFont.current().rawValue, forKey: SettingsKey.preComicFont)
            defaults.set(AppFont.comic.rawValue, forKey: SettingsKey.appFont)
        }
        engine.reloadAppearance()
    }

    private var needsPermission: Bool {
        engine.authorization == .denied || engine.authorization == .restricted
    }

    /// Show the auto-hiding control bezel and re-arm its fade-out.
    private func revealChrome() {
        withAnimation(.easeIn(duration: 0.15)) { chromeVisible = true }
        chromeHideTask?.cancel()
        chromeHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { chromeVisible = false }
        }
    }

    private func townSize(for size: CGSize) -> CGFloat {
        // Scale the headline to the screen; clamp for sanity.
        min(max(size.width * 0.16, 44), 120)
    }

    /// One bezel control: icon over a small text title.
    private func bezelControl(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Theme.primary.opacity(0.85))
            .frame(minWidth: 54)
        }
        .buttonStyle(.plain)
    }

    /// Rasterize the current screen — backdrop plus readout, honoring any
    /// scrub/zoom — and hand it to the share sheet.
    private func shareImage(size: CGSize) {
        let scrub = scrubbedReadout()
        let snapshot = ShareSnapshotView(
            state: scrub.state, displayDate: scrub.displayDate, size: size,
            samples: activeTrack.samples, pauseMarks: activeTrack.pauseMarks,
            playhead: slopeSelected ?? activeTrack.activeDuration, zoom: routeZoom)
        let renderer = ImageRenderer(content: snapshot)
        renderer.scale = 3
        guard let image = renderer.uiImage else { return }
        shareItem = ShareItem(items: [image])
    }

    /// Export the displayed trail (live, or the playback route) as a JSON file.
    private func shareJSON() {
        guard let url = RouteStore.shared.exportURL(for: activeTrack) else { return }
        shareItem = ShareItem(items: [url])
    }

    /// Load a saved route for playback: trail-driven views switch to it, and if
    /// a non-trail background is active, hop to Route so there's something to
    /// see. The snap-to-present control exits back to live.
    private func startPlayback(_ route: SavedRoute) {
        if let art = BackgroundArt(rawValue: backgroundArt), art != .slope, art != .route {
            backgroundArt = BackgroundArt.route.rawValue
            engine.reloadAppearance()
        }
        playback = TrackLog(saved: route)
        slopeSelected = nil
        slopeDragAnchor = nil
    }

    /// The readout to show: live, or — while scrubbing a Slope/Route trail — the
    /// recorded readout at the playhead, with live-only fields (speed sign,
    /// flashes) suppressed and the time complication pinned to that moment.
    private func scrubbedReadout() -> (state: LocationActivityAttributes.ContentState, displayDate: Date?) {
        let art = BackgroundArt(rawValue: backgroundArt)
        // During playback the readout retraces even un-scrubbed (playhead sits
        // at the recording's end); live, only an actual scrub retraces.
        guard art == .slope || art == .route,
              slopeSelected != nil || playback != nil,
              let sample = activeTrack.sample(atActive: slopeSelected ?? activeTrack.activeDuration) else {
            return (engine.state, nil)
        }
        var s = engine.state
        s.town = sample.town
        s.road = sample.road
        s.route = sample.route
        s.altitudeMeters = sample.altitudeMeters
        s.headingDegrees = sample.headingDegrees
        s.headingContinuous = sample.headingContinuous
        s.temperatureC = sample.temperatureC
        s.speedLimitKmh = nil        // not recorded on the trail; a live-only concept
        s.townChanged = false
        s.roadChanged = false
        s.headingChanged = false
        s.speedLimitChanged = false
        s.timeChanged = false
        s.temperatureChanged = false
        return (s, sample.date)
    }

    /// Pan the playhead through the trip (Slope and Route share this): drag right
    /// to rewind toward the first recording, back to snap to live. A no-op unless
    /// one of those backgrounds is active. `minimumDistance` keeps taps (chrome,
    /// Easter egg) working.
    private func scrubDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let art = BackgroundArt(rawValue: backgroundArt)
                guard art == .slope || art == .route, activeTrack.isScrubable else { return }
                let pps = BackgroundArtRenderer.slopePointsPerSecond(width: width)
                guard pps > 0 else { return }
                if slopeDragAnchor == nil { slopeDragAnchor = slopeSelected ?? activeTrack.activeDuration }
                // Drag right (positive width) reveals earlier time. The axis is
                // active time, so a park's dead time is a seam, not a span.
                let deltaSeconds = Double(value.translation.width / pps)
                let target = slopeDragAnchor! - deltaSeconds
                let clamped = min(max(target, 0), activeTrack.activeDuration)
                // Within a second of the end: back to nil — live tracking, or
                // (in playback) resting at the recording's end.
                let newSelected: TimeInterval? =
                    activeTrack.activeDuration - clamped < 1 ? nil : clamped
                scrubHaptics(target: target, clamped: clamped, newSelected: newSelected)
                slopeSelected = newSelected
            }
            .onEnded { _ in
                slopeDragAnchor = nil
                scrubEdgeLatched = false
            }
    }

    /// Tactile feedback while scrubbing: a light bump crossing a pause seam,
    /// a firmer one arriving at either end of the trail. The edge bump latches
    /// so holding a drag past the clamp doesn't machine-gun.
    private func scrubHaptics(target: TimeInterval, clamped: TimeInterval,
                              newSelected: TimeInterval?) {
        let oldPlayhead = slopeSelected ?? activeTrack.activeDuration
        let newPlayhead = newSelected ?? activeTrack.activeDuration

        // Seam crossings: sign change across a mark. One bump per update even
        // if a fast drag jumps several seams.
        if activeTrack.pauseMarks.contains(where: {
            ($0 - oldPlayhead) * ($0 - newPlayhead) < 0
        }) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // Ends: pushed past the first recording, or arrived back at the
        // present (the moment the scrub snaps to live / the recording's end).
        let atStart = clamped == 0 && target < 0
        let atEnd = newSelected == nil && slopeSelected != nil
        if atStart || atEnd {
            if !scrubEdgeLatched {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                scrubEdgeLatched = true
            }
        } else if clamped > 0 {
            scrubEdgeLatched = false
        }
    }

    /// Pinch to zoom the Route map. Zoom floors at 1 (the whole route fit to the
    /// view — you can't zoom out past its extent) and caps at the renderer's max.
    /// A no-op unless Route is the active background.
    private func routePinch() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard BackgroundArt(rawValue: backgroundArt) == .route else { return }
                routeZoom = clampZoom(routeZoomBase * scale)
            }
            .onEnded { scale in
                guard BackgroundArt(rawValue: backgroundArt) == .route else { return }
                routeZoomBase = clampZoom(routeZoomBase * scale)
                routeZoom = routeZoomBase
            }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, BackgroundArtRenderer.routeMinZoom), BackgroundArtRenderer.routeMaxZoom)
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "location.slash")
                .font(.system(size: 44))
                .foregroundColor(Theme.muted)
            Text("Location access is off")
                .font(engine.state.font(size: 22, weight: .bold))
                .foregroundColor(Theme.primary)
            Text("You Are Here needs your location to name the town, road, and heading around you.")
                .font(engine.state.font(size: 15, weight: .regular))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(engine.state.font(size: 16, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(Theme.primary)
            .clipShape(Capsule())
        }
        .padding(32)
    }

    /// Shown after an explicit Stop (Settings ▸ Stop). Confirms the Lock-Screen
    /// readout is cleared, teaches that closing the app wouldn't have done that,
    /// and offers a fresh Start.
    private var stoppedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "stop.circle")
                .font(.system(size: 44))
                .foregroundColor(Theme.muted)
            Text("Stopped")
                .font(engine.state.font(size: 22, weight: .bold))
                .foregroundColor(Theme.primary)
            Text("The Live Activity is stopped. You may now quit the app by swiping it away.")
                .font(engine.state.font(size: 15, weight: .regular))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Start") {
                engine.start()
            }
            .font(engine.state.font(size: 16, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(Theme.primary)
            .clipShape(Capsule())
        }
        .padding(32)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: LocationEngine
    @AppStorage(SettingsKey.unitIsMetric) private var unitIsMetric = false
    @AppStorage(SettingsKey.unitIsCelsius) private var unitIsCelsius = false
    @AppStorage(SettingsKey.clock24) private var clock24 = false
    @AppStorage(SettingsKey.complications) private var complications = Complication.defaultRaw
    @AppStorage(SettingsKey.refreshSeconds) private var refreshSeconds = 1
    @AppStorage(SettingsKey.onlineRouteLookup) private var onlineRouteLookup = false
    @AppStorage(SettingsKey.showSpeedLimit) private var showSpeedLimit = false
    @AppStorage(SettingsKey.pictureInPicture) private var pictureInPicture = false
    @AppStorage(SettingsKey.pipLargeWindow) private var pipLargeWindow = false
    @AppStorage(SettingsKey.appFont) private var appFont = AppFont.helvetica.rawValue
    @AppStorage(SettingsKey.lightMode) private var lightMode = false
    @AppStorage(SettingsKey.customFlashColor) private var customFlashColor = false
    @AppStorage(SettingsKey.flashColorHex) private var flashColorHex = "FFFFFF"
    @AppStorage(SettingsKey.backgroundArt) private var backgroundArt = BackgroundArt.off.rawValue
    @AppStorage(SettingsKey.backgroundContrast) private var backgroundContrast = 1.0

    /// ColorPicker binding backed by the hex string in UserDefaults.
    private var flashColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: flashColorHex) ?? .white },
            set: { newValue in
                flashColorHex = newValue.hexString ?? "FFFFFF"
                engine.reloadAppearance()
            })
    }

    /// On/off binding for one complication, backed by the comma-joined string.
    private func complicationBinding(_ c: Complication) -> Binding<Bool> {
        Binding(
            get: { Complication.decode(complications).contains(c) },
            set: { on in
                var set = Set(Complication.decode(complications))
                if on { set.insert(c) } else { set.remove(c) }
                complications = Complication.encode(Array(set))
                engine.reloadAppearance()
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Toggle("Light mode", isOn: $lightMode)
                        .onChange(of: lightMode) { _ in engine.reloadAppearance() }
                    Toggle("Custom flash color", isOn: $customFlashColor)
                        .onChange(of: customFlashColor) { _ in engine.reloadAppearance() }
                    if customFlashColor {
                        ColorPicker("Flash color", selection: flashColorBinding, supportsOpacity: false)
                    }
                    Text("Fields briefly flash when their value changes.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Picker("Background", selection: $backgroundArt) {
                        Text("Off").tag(BackgroundArt.off.rawValue)
                        Text("Streets").tag(BackgroundArt.streets.rawValue)
                        Text("Topo").tag(BackgroundArt.topo.rawValue)
                        Text("Procedural").tag(BackgroundArt.procedural.rawValue)
                        Text("Neon").tag(BackgroundArt.neon.rawValue)
                        Text("Slope").tag(BackgroundArt.slope.rawValue)
                        Text("Route").tag(BackgroundArt.route.rawValue)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: backgroundArt) { _ in engine.reloadAppearance() }
                    if backgroundArt != BackgroundArt.off.rawValue {
                        HStack {
                            Text("Contrast")
                            // App preview updates live (views read the value
                            // directly); Live Activity/PiP sync on release.
                            Slider(value: $backgroundContrast, in: 0.4...2.4) { editing in
                                if !editing { engine.reloadAppearance() }
                            }
                        }
                    }
                    Text("Streets (app-only) sketches a tilted, slowly turning abstract of nearby roads. Topo (app-only) draws real elevation contours around you. Procedural is imagined elevation contours. Neon (dark only) is a synthwave grid that mirrors your driving speed. Slope (app-only) charts your altitude over the drive so far (swipe to rewind). Route maps the path you've taken (swipe to rewind, pinch to zoom)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Font") {
                    Picker("Font", selection: $appFont) {
                        ForEach(AppFont.selectable) { family in
                            // Each option previews in its own face.
                            Text(family.label)
                                .font(Theme.font(size: 17, weight: .medium, family: family))
                                .tag(family.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: appFont) { _ in engine.reloadAppearance() }
                    Text("FS Millbank is a wayfinding face by Fontsmith. Overpass is an open-source take on U.S. highway signage lettering.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Complications") {
                    ForEach(Complication.allCases) { comp in
                        Toggle(comp.label, isOn: complicationBinding(comp))
                    }
                    Text("Temperature is fetched from Open-Meteo")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Units") {
                    Picker("Distance", selection: $unitIsMetric) {
                        Text("Imperial (ft/mi)").tag(false)
                        Text("Metric (m/km)").tag(true)
                    }
                    .onChange(of: unitIsMetric) { _ in engine.reloadAppearance() }
                    Picker("Temperature", selection: $unitIsCelsius) {
                        Text("°F").tag(false)
                        Text("°C").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: unitIsCelsius) { _ in engine.reloadAppearance() }
                    Picker("Clock", selection: $clock24) {
                        Text("12-hour").tag(false)
                        Text("24-hour").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: clock24) { _ in engine.reloadAppearance() }
                }
                Section("Update rate") {
                    Picker("Refresh", selection: $refreshSeconds) {
                        ForEach(RefreshRate.allCases) { rate in
                            Text(rate.label).tag(rate.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: refreshSeconds) { _ in engine.reloadRefreshRate() }
                    Text(refreshFootnote)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Route numbers") {
                    Toggle("Add route numbers", isOn: $onlineRouteLookup)
                    Text("When Apple labels a road only by its street name, look up its route number (e.g. ME-131) from OpenStreetMap.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Speed limit") {
                    Toggle("Show speed limit", isOn: $showSpeedLimit)
                    Text("Show the posted speed limit from OpenStreetMap when available.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Floating window") {
                    Toggle("Float over other apps", isOn: $pictureInPicture)
                    Picker("Window size", selection: $pipLargeWindow) {
                        Text("Small").tag(false)
                        Text("Large").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text("When you leave the app, keep the readout in a floating window over other apps. Use play/pause to suspend wayfinding while parking.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Stopping") {
                    Button(role: .destructive) {
                        engine.endSession()
                        dismiss()
                    } label: {
                        Label("Stop & clear the Lock Screen", systemImage: "stop.circle")
                    }
                    Text("Your readout appears on the Lock Screen (a Live Activity) while You Are Here runs. That readout is separate from the app and keeps going even if you swipe the app closed from the App Switcher. To stop the app completely, tap stop and then swipe the app away.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Text("<privacy policy link> <developer and version info>")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("You Are Here")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Convenience Stop, since the full "Stopping" section is at the
                    // very bottom. Same action as that section's button. An explicit
                    // HStack, because a Label collapses to icon-only in the nav bar.
                    Button(role: .destructive) {
                        engine.endSession()
                        dismiss()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.circle")
                            Text("Stop")
                        }
                    }
                    .tint(.red)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var refreshFootnote: String {
        switch RefreshRate(rawValue: refreshSeconds) ?? .s1 {
        case .s1, .s2:
            return "Faster updates and full GPS accuracy. Responsive and accurate."
        case .s5, .s10:
            return "Slower updates save battery and heat. Coarser altitude and position."
        }
    }
}
