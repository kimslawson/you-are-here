# you-are-here

An iPhone app + Live Activity that shows, at a glance, **where you are** —
current town, current road (with highway shield if you're on a numbered route),
compass heading, and altitude. For when your kids won't stop asking "are we
there yet?" and you don't want to keep poking at Maps or asking Siri.

```
 Donner Pass Rd  ·  ⬡ I-80
 TRUCKEE
 ⛰ 5,958 ft  ·  ↗ NW 305°
```

- **Line 1 (small):** road name, plus the route name and a highway shield if
  you're on a numbered route (Interstate / US / state).
- **Line 2 (big):** town name — the headline.
- **Line 3 (small):** altitude and compass heading.

The same three lines appear in three places: the **Lock Screen Live Activity**,
the **Dynamic Island**, and the **full-screen app** (handy propped on the dash).

When the **town, road, or compass direction changes**, that field briefly
**flashes white** so a glance catches it.

---

## Design notes

- **Font:** Helvetica Neue (bundled on iOS) — a neo-grotesque in the lineage of
  road/transit signage, picked for glanceable wayfinding. Change one constant
  (`Theme.family`) to fall back to the system font (SF Pro).
- **Palette:** bright off-white text on true black for contrast and OLED
  comfort; pure white for the change-flash. Centralized in `Shared/Theme.swift`.
- **Units:** Imperial by default, with an in-app Imperial/Metric toggle.
- **Compass:** true north (falls back to magnetic if true north is unavailable).
- **Altitude:** GPS (absolute) fused with the barometer (smooth, responsive) —
  see `AltitudeFuser.swift`.
- **Parked mode:** a pause/play button at the trailing end of the
  altitude/heading line (both on screen and in the Live Activity). Parking
  freezes the readout and powers down the sensors to save battery; the screen is
  also allowed to sleep. It stays parked until you tap play (manual resume).
  The Live Activity button is interactive on iOS 17+ (via an App Intent that
  runs in the app process and relaunches it if needed); on iOS 16 it shows the
  state but tapping opens the app instead.

## How it updates

A navigation-style app holds **continuous background location**, which keeps the
app alive to refresh the Live Activity even with the screen locked.

- The **on-screen app** refreshes once per second.
- The **Live Activity** refreshes immediately on the important wayfinding
  changes (town / road / route / compass direction — the ones that flash), and
  for altitude/heading drift no more than every few seconds. iOS enforces a
  Live Activity update *budget*; this cadence stays well inside it while still
  feeling live. Tune via `activityNumericInterval` in `LocationEngine.swift`.
  The `NSSupportsLiveActivitiesFrequentUpdates` entitlement is set.

## ⚠️ Offline place naming — important

Place names come from Apple's `CLGeocoder`, which **requires a network
connection**. Apple provides **no offline reverse geocoding** API (MapKit's
downloadable offline maps are available only to Apple's own Maps app).

So in this first version:

- **With signal:** full town / road / route naming.
- **Without signal:** compass and altitude stay fully live; place names show the
  **last known** value with a "no signal" indicator.

Geocoding is behind the `PlaceProvider` protocol (`PlaceProvider.swift`). To add
true offline naming later — e.g. a bundled OpenStreetMap-derived gazetteer —
implement that protocol and have `LocationEngine` fall back to it when offline.
Nothing else needs to change. (Expect tens of MB to GBs depending on the
coverage region you bundle.)

---

## Building

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonsei/XcodeGen) so the project definition stays
readable and diff-able (the `.xcodeproj` itself is git-ignored).

```bash
brew install xcodegen        # once
xcodegen generate            # creates YouAreHere.xcodeproj
open YouAreHere.xcodeproj
```

Then in Xcode:

1. Select the **YouAreHere** target → **Signing & Capabilities** → pick your
   Team (a paid Apple Developer account is required for Live Activities on a
   device). Do the same for the **YouAreHereWidgetExtension** target.
2. Set a unique bundle id prefix if `com.kimslawson` is taken.
3. Build & run on a **real device** (Live Activities, the barometer, and
   background location don't work in the Simulator).
4. Make sure **Settings → Face ID & Passcode → Live Activities** and the app's
   own Live Activities permission are enabled.

**Requirements:** iOS 16.2+, Xcode 15+, a device with a barometer (all modern
iPhones), and a paid Apple Developer account for on-device Live Activities.

## Project layout

```
project.yml                     XcodeGen project definition
Shared/                         Compiled into BOTH app and widget
  LocationActivityAttributes    Live Activity data model (shared contract)
  Theme                         Fonts + colors
  WayfindingView                The three-line layout (app + lock screen)
  RouteShield                   Highway shields drawn in SwiftUI (no assets)
  RouteParser                   Heuristic route-number extraction
  Formatting                    Units, cardinal direction, route labels
YouAreHere/                     App target
  YouAreHereApp / ContentView   Full-screen UI + settings
  LocationEngine                CoreLocation + heading + altitude + Live Activity
  PlaceProvider                 Geocoding abstraction (Apple online today)
  AltitudeFuser                 GPS + barometer fusion
  Settings                      UserDefaults keys
YouAreHereWidget/               Widget extension target
  YouAreHereLiveActivity        Lock Screen + Dynamic Island presentations
```

## Known limitations / next steps

- **Route shields are heuristic.** Apple's geocoder doesn't return a structured
  route number, so `RouteParser` pattern-matches the road text ("I-80",
  "US Highway 50", "CA-89", "State Route 89"). Some roads won't match and will
  show as a plain name. Improving this is a good place for the offline dataset.
- **Offline naming** isn't implemented yet (see the warning above).
- Shields are stylized, not pixel-accurate MUTCD artwork.
