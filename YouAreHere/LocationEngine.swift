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

    // MARK: Published state for the on-screen app
    @Published private(set) var state = LocationActivityAttributes.ContentState(
        town: "", road: "", route: nil, altitudeMeters: nil, headingDegrees: nil,
        unitIsMetric: false, hasSignal: true,
        townChanged: false, roadChanged: false, headingChanged: false)
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isRunning = false

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

    // MARK: Tick throttle
    private var tickTimer: Timer?
    private var lastTick = Date.distantPast
    private let tickInterval: TimeInterval = 1.0

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
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 1   // degrees
        manager.headingOrientation = .portrait
        authorization = manager.authorizationStatus
        updateHeadingOrientation()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.networkAvailable = (path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
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
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateHeadingOrientation() }
        }

        tickTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(force: false) }
        }

        startLiveActivity()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        fuser.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        endLiveActivity()
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
        let now = Date()
        guard force || now.timeIntervalSince(lastTick) >= tickInterval - 0.05 else { return }
        lastTick = now

        guard let loc = latestLocation else { return }

        maybeGeocode(loc)

        let metric = UserDefaults.standard.unitIsMetric
        let town = lastPlace?.town ?? ""
        let road = lastPlace?.road ?? ""
        let route = lastPlace?.route
        let routeLabel = route.map(Formatting.routeLabel)
        let altitude = fuser.altitudeMeters ?? (loc.verticalAccuracy > 0 ? loc.altitude : nil)
        let heading = latestHeading
        let cardinal = heading.map(Formatting.cardinal)

        // Flash detection: compare to last committed display values.
        let townChanged = lastTown != nil && town != lastTown && !town.isEmpty
        let roadChanged = lastRoad != nil && (road != lastRoad || routeLabel != lastRouteLabel)
        let headingChanged = lastCardinal != nil && cardinal != nil && cardinal != lastCardinal

        let newState = LocationActivityAttributes.ContentState(
            town: town, road: road, route: route,
            altitudeMeters: altitude, headingDegrees: heading,
            unitIsMetric: metric, hasSignal: networkAvailable,
            townChanged: townChanged, roadChanged: roadChanged, headingChanged: headingChanged)

        state = newState

        // Commit the displayed values for the next comparison.
        lastTown = town
        lastRoad = road
        lastRouteLabel = routeLabel
        if let cardinal { lastCardinal = cardinal }

        pushActivityIfNeeded(newState, important: townChanged || roadChanged || headingChanged)
    }

    // MARK: Geocoding

    private func maybeGeocode(_ location: CLLocation) {
        guard placeProvider.requiresNetwork ? networkAvailable : true else { return }
        guard !geocodeInFlight else { return }

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
                }
            } catch {
                // Network blip or no result: keep the last known place (stale).
                // hasSignal is driven by NWPathMonitor, so the UI shows offline.
            }
        }
    }

    // MARK: Live Activity

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activity == nil else { return }
        let attributes = LocationActivityAttributes(title: "You Are Here")
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
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
