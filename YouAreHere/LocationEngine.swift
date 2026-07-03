import Foundation
import CoreLocation
import Combine
import Network
import ActivityKit
import UIKit

/// Drives everything: location + heading from CoreLocation, fused altitude,
/// throttled reverse geocoding, and the Live Activity. Publishes a single
/// `ContentState` the full-screen app renders directly.
@MainActor
final class LocationEngine: NSObject, ObservableObject {

    /// Shared instance so the Live Activity's pause intent (which runs in the
    /// app process) can reach the live engine.
    static let shared = LocationEngine()

    // MARK: Published state for the on-screen app
    @Published private(set) var state = LocationActivityAttributes.ContentState(
        town: "", road: "", route: nil, altitudeMeters: nil, headingDegrees: nil,
        headingContinuous: nil,
        unitIsMetric: false, hasSignal: true, isPaused: false, speedLimitKmh: nil,
        townChanged: false, roadChanged: false, headingChanged: false, speedLimitChanged: false)
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isRunning = false
    /// "Parked": sensors frozen to save battery. Per-session only — a fresh
    /// launch always starts live, never parked.
    @Published private(set) var isPaused = false

    // MARK: Collaborators
    private let manager = CLLocationManager()
    private let fuser = AltitudeFuser()
    private let placeProvider: PlaceProvider = AppleGeocoder()
    private let pathMonitor = NWPathMonitor()

    // MARK: Live inputs
    private var latestLocation: CLLocation?
    private var latestHeading: CLLocationDirection?   // true north degrees
    private var networkAvailable = true

    // MARK: Geocoding throttle
    private var lastGeocodedLocation: CLLocation?
    private var geocodeInFlight = false
    private var lastPlace: ResolvedPlace?
    /// Re-geocode after moving this far (meters) or this much time, whichever first.
    private let geocodeDistanceThreshold: CLLocationDistance = 40
    private let geocodeMinInterval: TimeInterval = 12
    private var lastGeocodeAttempt = Date.distantPast

    // MARK: Online road info (opt-in; fills route numbers + speed limit Apple omits)
    private let roadInfoResolver: RoadInfoResolver = OverpassRoadInfoResolver()
    private var roadInfoInFlight = false
    private var lastRoadInfoLookup = Date.distantPast
    /// The road we last resolved info for, and the result (a resolved road with
    /// nil fields means "looked up, found nothing" — so we don't keep retrying).
    private var roadInfoRoad: String?
    private var roadInfoResult = RoadInfo()
    /// Minimum spacing between Overpass calls, on top of the once-per-road gate.
    private let roadInfoMinInterval: TimeInterval = 5
    /// Last committed speed limit (km/h), for the change-flash.
    private var lastSpeedKmh: Double?

    // MARK: Tick throttle
    private var tickTimer: Timer?
    private var lastTick = Date.distantPast
    private var refreshRate: RefreshRate = .s1
    private var tickInterval: TimeInterval { refreshRate.interval }

    // MARK: Heading animation
    /// Continuous (unwrapped) heading so the arrow rotates the short way across
    /// north in both the app and the Live Activity. Resets per process, so it
    /// never grows unbounded across sessions.
    private var continuousHeading: Double?

    // MARK: Flash comparison (the "last committed" displayed values)
    private var lastTown: String?
    private var lastRoad: String?
    private var lastRouteLabel: String?
    private var lastCardinal: String?

    // MARK: Live Activity
    private var activity: Activity<LocationActivityAttributes>?
    private var lastActivityPush = Date.distantPast
    private var lastPushedAltitudeString: String?
    private var lastPushedHeadingString: String?
    /// Whether the last state we pushed had a field flashing, so we know to push
    /// a prompt follow-up that clears the flash.
    private var lastPushedHadFlash = false
    /// Live Activity gets numeric-only refreshes no more often than this, to
    /// stay within the system's update budget. Important wayfinding changes
    /// (town/road/route/cardinal) push immediately regardless.
    private let activityNumericInterval: TimeInterval = 3.0

    // MARK: Heading orientation
    private var orientationObserver: NSObjectProtocol?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingOrientation = .portrait
        authorization = manager.authorizationStatus
        refreshRate = RefreshRate.current()
        applyRefreshConfiguration()   // sets accuracy + distance/heading filters
        updateHeadingOrientation()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkAvailable = (path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        // Let the Live Activity's pause button reach us.
        LiveActivityActions.togglePause = { [weak self] in self?.togglePause() }
    }

    deinit {
        // Defensive cleanup if the engine is ever torn down (it's normally an
        // app-lifetime object). NWPathMonitor.cancel and removeObserver are
        // both safe to call off the main actor.
        pathMonitor.cancel()
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
    }

    // MARK: Lifecycle

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            // Ask for Always so updates continue with the screen locked.
            manager.requestAlwaysAuthorization()
        default:
            break
        }

        startLiveActivity()

        // A pause set before start (the Live Activity button can park us after
        // a cold launch): keep the sensors off, just show the frozen readout.
        if isPaused {
            pushFrozenState()
        } else {
            startSensors()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        suspendSensors()
        endLiveActivity()
    }

    // MARK: Park / resume

    func togglePause() {
        // The Live Activity button can cold-launch us with no session running.
        // Pause is never persisted, so adopt whatever paused state the activity
        // is currently showing — that's what the user tapped against — so the
        // toggle goes the direction they expect.
        if !isRunning, activity == nil,
           let shown = Activity<LocationActivityAttributes>.activities.first?.content.state.isPaused {
            isPaused = shown
        }
        setPaused(!isPaused)
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused

        if paused {
            suspendSensors()
            pushFrozenState()           // freeze the readout, flip icon to play
        } else {
            if !isRunning {
                start()                 // resume even if we were relaunched cold
            } else {
                startSensors()
            }
            pushFrozenState()           // immediately flip icon to pause
        }
    }

    // MARK: Sensor lifecycle

    private func startSensors() {
        if manager.authorizationStatus == .authorizedAlways
            || manager.authorizationStatus == .authorizedWhenInUse {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }

        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        fuser.start()

        // Keep the heading reference in sync with how the device is held, so the
        // compass reads the same physical direction in portrait and landscape.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        updateHeadingOrientation()
        if orientationObserver == nil {
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.updateHeadingOrientation() }
            }
        }

        scheduleTickTimer()
    }

    private func scheduleTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(force: false) }
        }
    }

    /// Push the current refresh rate down to CoreLocation. Cheap to call anytime.
    private func applyRefreshConfiguration() {
        manager.desiredAccuracy = refreshRate.desiredAccuracy
        manager.distanceFilter = refreshRate.distanceFilter
        manager.headingFilter = refreshRate.headingFilter
        // Rebuild the tick at the new cadence only if it's currently running.
        if tickTimer != nil { scheduleTickTimer() }
    }

    /// Re-read the user's refresh-rate choice and apply it live.
    func reloadRefreshRate() {
        let rate = RefreshRate.current()
        guard rate != refreshRate else { return }
        refreshRate = rate
        applyRefreshConfiguration()
    }

    private func suspendSensors() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        fuser.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// Map the physical device orientation onto CoreLocation's heading reference.
    /// `CLDeviceOrientation` mirrors `UIDeviceOrientation`'s cases, so a held
    /// device's "top of screen" points the same way in every orientation. Flat
    /// (faceUp/faceDown) and unknown are ignored so we keep the last upright
    /// reference instead of jumping.
    private func updateHeadingOrientation() {
        let orientation: CLDeviceOrientation
        switch UIDevice.current.orientation {
        case .portrait:            orientation = .portrait
        case .portraitUpsideDown:  orientation = .portraitUpsideDown
        case .landscapeLeft:       orientation = .landscapeLeft
        case .landscapeRight:      orientation = .landscapeRight
        default:                   return   // faceUp / faceDown / unknown
        }
        manager.headingOrientation = orientation
    }

    // MARK: Tick

    private func tick(force: Bool) {
        guard !isPaused else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastTick) >= tickInterval - 0.05 else { return }
        lastTick = now

        guard let loc = latestLocation else { return }

        maybeGeocode(loc)

        let metric = UserDefaults.standard.unitIsMetric
        let town = lastPlace?.town ?? ""
        let road = lastPlace?.road ?? ""
        // Online road info (route + speed) applies only while it matches this road.
        let haveInfo = road == roadInfoRoad
        // Prefer Apple's route; otherwise use the online lookup result if enabled.
        let onlineRoute = UserDefaults.standard.bool(forKey: SettingsKey.onlineRouteLookup)
            && haveInfo ? roadInfoResult.route : nil
        let route = lastPlace?.route ?? onlineRoute
        let routeLabel = route.map(Formatting.routeLabel)
        let speedKmh = UserDefaults.standard.bool(forKey: SettingsKey.showSpeedLimit)
            && haveInfo ? roadInfoResult.speedLimitKmh : nil
        let altitude = fuser.altitudeMeters ?? (loc.verticalAccuracy > 0 ? loc.altitude : nil)
        let heading = latestHeading
        let cardinal = heading.map(Formatting.cardinal)

        // Accumulate a continuous heading (shortest signed step) for the arrow.
        if let heading {
            if let cur = continuousHeading {
                var delta = (heading - cur).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                continuousHeading = cur + delta
            } else {
                continuousHeading = heading
            }
        }

        // Flash detection: compare to last committed display values.
        let townChanged = lastTown != nil && town != lastTown && !town.isEmpty
        let roadChanged = lastRoad != nil && (road != lastRoad || routeLabel != lastRouteLabel)
        let headingChanged = lastCardinal != nil && cardinal != nil && cardinal != lastCardinal
        let speedChanged = lastSpeedKmh != nil && speedKmh != nil && speedKmh != lastSpeedKmh

        let newState = LocationActivityAttributes.ContentState(
            town: town, road: road, route: route,
            altitudeMeters: altitude, headingDegrees: heading,
            headingContinuous: continuousHeading,
            unitIsMetric: metric, hasSignal: networkAvailable, isPaused: false,
            speedLimitKmh: speedKmh,
            townChanged: townChanged, roadChanged: roadChanged, headingChanged: headingChanged,
            speedLimitChanged: speedChanged)

        state = newState

        // Commit the displayed values for the next comparison.
        lastTown = town
        lastRoad = road
        lastRouteLabel = routeLabel
        if let cardinal { lastCardinal = cardinal }
        if let speedKmh { lastSpeedKmh = speedKmh }

        pushActivityIfNeeded(newState, important: townChanged || roadChanged || headingChanged || speedChanged)
    }

    /// Push the current (frozen) readout with the latest `isPaused`, clearing
    /// flash flags. Used when parking/resuming so the Live Activity and on-screen
    /// UI flip the pause/play icon immediately without waiting for a tick.
    private func pushFrozenState() {
        // Reconnect to a system-shown Activity if the pause intent cold-launched
        // us, and adopt its content while ours is still blank — so the freeze
        // keeps the readout the user was looking at instead of blanking it.
        if activity == nil {
            startLiveActivity()
            if let shown = activity?.content.state, state.town.isEmpty, state.road.isEmpty {
                state = shown
            }
        }

        var s = state
        s.isPaused = isPaused
        s.townChanged = false
        s.roadChanged = false
        s.headingChanged = false
        s.speedLimitChanged = false
        state = s

        guard let activity else { return }
        let content = ActivityContent(state: s, staleDate: nil)
        Task { await activity.update(content) }
    }

    // MARK: Geocoding

    private func maybeGeocode(_ location: CLLocation) {
        guard placeProvider.requiresNetwork ? networkAvailable : true else { return }
        // Watchdog: normally one request at a time, but if a request ever wedges
        // (its continuation never resumes) don't let geocoding die for the whole
        // session — let a new one through after a generous timeout.
        if geocodeInFlight && Date().timeIntervalSince(lastGeocodeAttempt) < 30 { return }

        let movedEnough = lastGeocodedLocation.map {
            location.distance(from: $0) >= geocodeDistanceThreshold
        } ?? true
        let waitedEnough = Date().timeIntervalSince(lastGeocodeAttempt) >= geocodeMinInterval
        guard (movedEnough || lastPlace == nil) && waitedEnough else { return }

        geocodeInFlight = true
        lastGeocodeAttempt = Date()
        let target = location

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.geocodeInFlight = false } }
            do {
                let place = try await self.placeProvider.resolve(target)
                await MainActor.run {
                    self.lastPlace = place
                    self.lastGeocodedLocation = target
                    self.maybeLookupRoadInfo(target: target, place: place)
                }
            } catch {
                // Network blip or no result: keep the last known place (stale).
                // hasSignal is driven by NWPathMonitor, so the UI shows offline.
            }
        }
    }

    /// Fetch road info (route number + speed limit) from OpenStreetMap when the
    /// user has opted into either feature. Fires at most once per *road change*
    /// (and never faster than `roadInfoMinInterval`) to respect Overpass's
    /// fair-use limits.
    private func maybeLookupRoadInfo(target: CLLocation, place: ResolvedPlace) {
        let wantRoute = UserDefaults.standard.bool(forKey: SettingsKey.onlineRouteLookup) && place.route == nil
        let wantSpeed = UserDefaults.standard.bool(forKey: SettingsKey.showSpeedLimit)
        guard wantRoute || wantSpeed else { return }
        guard networkAvailable else { return }
        let road = place.road
        guard !road.isEmpty else { return }
        guard road != roadInfoRoad else { return }          // already handled this road
        // Watchdog + minimum spacing between calls.
        if roadInfoInFlight && Date().timeIntervalSince(lastRoadInfoLookup) < 30 { return }
        guard Date().timeIntervalSince(lastRoadInfoLookup) >= roadInfoMinInterval else { return }

        roadInfoInFlight = true
        lastRoadInfoLookup = Date()

        Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.roadInfoInFlight = false } }
            let info = (try? await self.roadInfoResolver.roadInfo(near: target, matching: road)) ?? RoadInfo()
            await MainActor.run {
                // Record the result against the road so we don't re-query it,
                // whether or not we found anything.
                self.roadInfoRoad = road
                self.roadInfoResult = info
            }
        }
    }

    // MARK: Live Activity

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }

        // If we were relaunched (e.g. cold-started by the pause intent), reconnect
        // to the Activity the system is already showing instead of making a new one.
        if let existing = Activity<LocationActivityAttributes>.activities.first {
            activity = existing
            return
        }

        var initial = state
        initial.isPaused = isPaused
        let attributes = LocationActivityAttributes(title: "You Are Here")
        let staleDate: Date? = isPaused ? nil : Date().addingTimeInterval(30)
        let content = ActivityContent(state: initial, staleDate: staleDate)
        do {
            activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        } catch {
            // Activities disabled or over the limit — app UI still works.
        }
    }

    private func pushActivityIfNeeded(_ newState: LocationActivityAttributes.ContentState, important: Bool) {
        guard let activity else {
            startLiveActivity()
            return
        }

        let altString = Formatting.altitudeString(meters: newState.altitudeMeters, metric: newState.unitIsMetric)
        let headString = Formatting.headingString(newState.headingDegrees)
        let numericChanged = altString != lastPushedAltitudeString || headString != lastPushedHeadingString
        let throttledOK = Date().timeIntervalSince(lastActivityPush) >= activityNumericInterval

        let hasFlash = newState.townChanged || newState.roadChanged || newState.headingChanged
        // Push promptly to clear a flash we previously showed.
        let flashClearingNeeded = lastPushedHadFlash && !hasFlash

        guard important || flashClearingNeeded || (numericChanged && throttledOK) else { return }

        lastActivityPush = Date()
        lastPushedAltitudeString = altString
        lastPushedHeadingString = headString
        lastPushedHadFlash = hasFlash

        let content = ActivityContent(state: newState, staleDate: Date().addingTimeInterval(30))
        Task { await activity.update(content) }
    }

    private func endLiveActivity() {
        guard let activity else { return }
        let final = ActivityContent(state: state, staleDate: nil)
        Task { await activity.end(final, dismissalPolicy: .immediate) }
        self.activity = nil
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationEngine: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorization = manager.authorizationStatus
            if self.isRunning,
               manager.authorizationStatus == .authorizedAlways
                || manager.authorizationStatus == .authorizedWhenInUse {
                manager.allowsBackgroundLocationUpdates = true
                manager.showsBackgroundLocationIndicator = true
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.latestLocation = loc
            self.fuser.ingestGPS(loc)
            // Drive ticks off location too, so updates continue in the background
            // (Timers don't fire reliably when suspended; location callbacks do).
            self.tick(force: false)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Prefer true north; fall back to magnetic if true is unavailable (-1).
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard value >= 0 else { return }
        Task { @MainActor in self.latestHeading = value }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient; NWPathMonitor handles the offline indicator.
    }
}
