import SwiftUI
import CoreLocation

/// Full-screen version of the widget: the same three lines, using the whole
/// display. Keeps the screen awake so it can ride on the dashboard.
struct ContentView: View {
    @EnvironmentObject private var engine: LocationEngine
    @AppStorage(SettingsKey.unitIsMetric) private var unitIsMetric = false
    @AppStorage(SettingsKey.pictureInPicture) private var pictureInPicture = false
    @StateObject private var pip = PiPManager()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

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
                GeometryReader { geo in
                    WayfindingView(state: engine.state,
                                   townSize: townSize(for: geo.size),
                                   alignment: .leading,
                                   // Portrait is cramped; double the speed sign.
                                   speedSignScale: geo.size.width < geo.size.height ? 2 : 1) {
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
            }

            // Tap-anywhere settings affordance.
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
                }
                Spacer()
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
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
    }

    private var needsPermission: Bool {
        engine.authorization == .denied || engine.authorization == .restricted
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
    @AppStorage(SettingsKey.appFont) private var appFont = AppFont.helvetica.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section("Font") {
                    Picker("Font", selection: $appFont) {
                        ForEach(AppFont.allCases) { family in
                            // Each option previews in its own face.
                            Text(family.label)
                                .font(Theme.font(size: 17, weight: .medium, family: family))
                                .tag(family.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: appFont) { _ in engine.reloadFont() }
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
                    Text("When you leave the app, keep the readout in a small floating window over other apps (Picture in Picture). Its play/pause button parks and resumes. Off by default.")
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
