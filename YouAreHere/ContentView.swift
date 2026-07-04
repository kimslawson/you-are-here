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
    /// Landscape-only: the gear is hidden until a tap reveals it (it shares the
    /// top-right corner with the speed-limit sign there). Portrait always shows it.
    @State private var chromeVisible = false
    @State private var chromeHideTask: Task<Void, Never>?
    // Easter egg: 10 quick taps swap to Comic; 10 more swap back.
    @State private var eggTaps = 0
    @State private var lastEggTap = Date.distantPast

    var body: some View {
        GeometryReader { geo in
            let isPortrait = geo.size.height >= geo.size.width
            ZStack {
                Theme.background.ignoresSafeArea()

                // A E S T H E T I C : the optional barely-there backdrop.
                // Neon is dark-mode only — dim glow lines have nothing to
                // glow against on white.
                if !needsPermission,
                   let art = BackgroundArt(rawValue: backgroundArt), art != .off,
                   !(art == .neon && engine.state.lightMode) {
                    BackgroundArtView(kind: art)
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
                } else {
                    WayfindingView(state: engine.state,
                                   townSize: townSize(for: geo.size),
                                   alignment: .leading,
                                   // Portrait is cramped; double the speed sign.
                                   speedSignScale: isPortrait ? 2 : 1) {
                        Button {
                            engine.togglePause()
                        } label: {
                            PauseGlyph(isPaused: engine.isPaused, size: townSize(for: geo.size) * 0.32)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 28)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                    .animation(.easeOut(duration: 0.25), value: engine.state)
                }

                // Settings gear, top-right.
                let showGear = isPortrait || chromeVisible
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(Theme.secondary.opacity(0.6))
                                .padding(16)
                        }
                        .opacity(showGear ? 1 : 0)
                        .allowsHitTesting(showGear)
                    }
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isPortrait { revealChrome() }
                registerEggTap()
            }
        }
        .onAppear {
            // Keep awake on the dash while live; allow sleep when parked.
            UIApplication.shared.isIdleTimerDisabled = !engine.isPaused
            engine.requestAuthorization()
            engine.start()
            pip.bind(to: engine)
            pip.setEnabled(pictureInPicture)
        }
        .onChange(of: engine.isPaused) { paused in
            UIApplication.shared.isIdleTimerDisabled = !paused
        }
        .onChange(of: pictureInPicture) { enabled in
            pip.setEnabled(enabled)
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
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .preferredColorScheme(engine.state.lightMode ? .light : .dark)
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

    /// Show the auto-hiding chrome (landscape gear) and re-arm its fade-out.
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
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: LocationEngine
    @AppStorage(SettingsKey.unitIsMetric) private var unitIsMetric = false
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

    /// ColorPicker binding backed by the hex string in UserDefaults.
    private var flashColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: flashColorHex) ?? .white },
            set: { newValue in
                flashColorHex = newValue.hexString ?? "FFFFFF"
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
                    Text("Light mode inverts the readout's black/white/gray palette. Fields briefly flash when their value changes — white by default (black in light mode), or a color of your choosing.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Picker("Background", selection: $backgroundArt) {
                        Text("Off").tag(BackgroundArt.off.rawValue)
                        Text("Streets").tag(BackgroundArt.streets.rawValue)
                        Text("Topo").tag(BackgroundArt.topo.rawValue)
                        Text("Neon").tag(BackgroundArt.neon.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Text("Purely aesthetic, barely-there backdrops behind the readout. Streets sketches a tilted, slowly turning abstract of nearby roads — deliberately useless for navigation (fetches geometry from OpenStreetMap; sends your location to overpass-api.de, like route lookup). Topo draws slowly drifting contour lines generated on-device — no network, not real terrain. Neon is a dim synthwave grid that scrolls at your actual driving speed; dark mode only.")
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
                    Text("Used across the app, the Live Activity, and the floating window. FS Millbank is a wayfinding face by Fontsmith; Overpass is an open-source take on U.S. highway signage lettering.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Units") {
                    Picker("Units", selection: $unitIsMetric) {
                        Text("Imperial (ft)").tag(false)
                        Text("Metric (m)").tag(true)
                    }
                    .pickerStyle(.segmented)
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
                    Toggle("Look up online", isOn: $onlineRouteLookup)
                    Text("When Apple labels a road only by its street name, look up its route number (e.g. ME-131) from OpenStreetMap. This sends your location to a third-party server (overpass-api.de) and needs a network connection. Off by default.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section("Speed limit") {
                    Toggle("Show speed limit", isOn: $showSpeedLimit)
                    Text("Show the posted speed limit from OpenStreetMap when available. Like route lookup, this sends your location to a third-party server (overpass-api.de) and needs a network connection — coverage is partial, especially on minor roads. Off by default.")
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
                    Text("When you leave the app, keep the readout in a floating window over other apps (Picture in Picture). Its play/pause button parks and resumes. Small is a slim strip; Large is taller with bigger, more legible type. Off by default.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Text("Compass uses true north. Place names come from Apple Maps and need a network connection; compass and altitude work offline.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("You Are Here")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var refreshFootnote: String {
        switch RefreshRate(rawValue: refreshSeconds) ?? .s1 {
        case .s1, .s2:
            return "Faster updates and full GPS accuracy — most responsive, most battery."
        case .s5, .s10:
            return "Slower updates ease off the GPS to save battery and heat. Altitude and town/road get a little coarser."
        }
    }
}
