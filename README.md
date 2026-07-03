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

- **Font:** user-selectable (*Settings ▸ Font*), applied across the app screen,
  Live Activity, and floating window — the choice travels to the widget process
  inside `ContentState.fontID` (no App Group). Options (`AppFont` in
  `Shared/Theme.swift`):
  - **Helvetica Neue** (default; ships with iOS) — a neo-grotesque in the
    lineage of road/transit signage, picked for glanceable wayfinding.
  - **San Francisco** — the system font (SF Pro).
  - **FS Millbank** — Fontsmith's wayfinding face (designed for UK signage
    programmes). ⚠️ Commercial font: the Regular/Bold TTFs in `Shared/Fonts/`
    are bundled under the repo owner's license and must not be redistributed —
    remove them if this repo is ever made public / forked.
  - **Overpass** — open-source (SIL OFL) digitization of U.S. Highway Gothic,
    fetched from Google Fonts; four weights bundled in `Shared/Fonts/`.
  - **Roadgeek 2005** — Michael Adams' recreations of the FHWA highway-sign
    series (Series D for small lines, E/E-Modified for emphasis). Freeware for
    recreational use; license bundled at `Shared/Fonts/Roadgeek-License.txt`
    (no commercial use).
  - **DIN 1451** — German road-signage standard, via its Roadgeek 2005
    Mittelschrift recreation (same license). Single weight, like the signs.
  - **DIN 1451 Engschrift** — the condensed DIN variant (used for long names
    on narrow signs), same Roadgeek recreation and license.
  - **Barlow** (OFL) — grotesque modeled on California highway signage.
  - **B612** (OFL) — commissioned by Airbus for cockpit displays; built for
    glanceable legibility on screens in vehicles.
  - **Atkinson Hyperlegible** (OFL) — Braille Institute face engineered for
    maximum character disambiguation.
  - **Inter** (OFL) — the workhorse open screen grotesque.
  - **Comic Neue** (OFL) — hidden from the picker; reserved for the Easter egg.

  All OFL fonts were fetched from Google Fonts. Adding another family: drop
  TTFs in `Shared/Fonts/`, add an `AppFont` case with a weight→face map (use
  PostScript names), and list the files under `UIAppFonts` in *both*
  Info.plists. (DIN 1451 and Roadgeek 2005 were wanted but aren't hosted
  anywhere this workspace's network could reach — drop-in candidates later.)
- **Palette:** bright off-white text on true black for contrast and OLED
  comfort; pure white for the change-flash. Centralized in `Shared/Theme.swift`.
  *Settings ▸ Appearance* offers **light mode** (a straightforward inversion of
  the black/white/gray values) and a **custom flash color** (color picker,
  stored as hex; default is white — black in light mode). Both travel to the
  widget inside `ContentState`, like the font and units.
- **Easter egg:** tap the app screen 10 times in quick succession and the whole
  UI switches to Comic Sans (well, Comic Neue — iOS doesn't ship the real
  thing). Ten more taps restore whatever font you had before.
- **Settings gear:** always visible in portrait. In landscape it shares the
  top-right corner with the speed-limit sign, so it auto-hides — tap anywhere
  to reveal it for a few seconds.
- **Units:** Imperial by default, with an in-app Imperial/Metric toggle.
- **Update rate:** 1s (default) / 2s / 5s / 10s. This isn't just a UI cadence —
  it's a power profile: slower rates also relax GPS accuracy and the
  distance/heading filters so the receiver powers down between fixes (the real
  battery/heat lever). 1s–2s stay at full accuracy; 5s–10s trade some altitude
  and town/road precision for battery. See `RefreshRate` in `Settings.swift`.
- **Compass:** true north (falls back to magnetic if true north is unavailable).
- **Altitude:** GPS (absolute) fused with the barometer (smooth, responsive) —
  see `AltitudeFuser.swift`.
- **Parked mode:** a pause/play button at the trailing end of the
  altitude/heading line (both on screen and in the Live Activity). Parking
  freezes the readout and powers down the sensors to save battery; the screen is
  also allowed to sleep. It stays parked until you tap play (manual resume),
  but parking is per-session: a fresh app launch always starts live. While
  parked with no location yet, the big line reads "Paused" (not "Locating…").
  The Live Activity button is interactive on iOS 17+ (via an App Intent that
  runs in the app process and relaunches it if needed); on iOS 16 it shows the
  state but tapping opens the app instead.
- **Floating window (opt-in).** *Settings ▸ Floating window ▸ Float over other
  apps.* When you leave the app, the readout stays in a small Picture-in-Picture
  banner floating over other apps. A Small/Large toggle picks the banner
  shape: Small is a slim ≈3:1 strip, Large is 2:1 with proportionally bigger
  type for legibility. iOS only lets *video* float, so
  `PictureInPicture.swift` renders `WayfindingView` into video frames (one per
  engine update, via `ImageRenderer` → `AVSampleBufferDisplayLayer` →
  `AVPictureInPictureController`); the wide ~3:1 frame shape gives the window
  its banner aspect. The PiP play/pause control maps to park/resume; other
  interaction opens the app. **Off by default.** Requires the audio/PiP
  background mode. Note for distribution: Apple's review guidelines describe
  PiP as a video-playback feature, and non-video uses like this have
  historically been a rejection risk.

## How it updates

A navigation-style app holds **continuous background location**, which keeps the
app alive to refresh the Live Activity even with the screen locked.

- The **on-screen app** refreshes once per second.
- The **Live Activity** refreshes immediately on the important wayfinding
  changes (town / road / route / compass direction — the ones that flash), and
  for altitude/heading drift no more than every few seconds. iOS enforces a
  Live Activity update *budget*; this cadence stays well inside it while still
  feeling live. Tune via `activityNumericInterval` in `LocationEngine.swift`.
  The `NSSupportsLiveActivitiesFrequentUpdates` Info.plist key is set.

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

## Permissions & entitlements

### What the user is prompted for (first launch)

On first run iOS shows these system prompts, each backed by a usage string in
`YouAreHere/Info.plist`:

| Prompt | Info.plist key | Why |
|---|---|---|
| **Location** | `NSLocationWhenInUseUsageDescription` | Name the town/road, heading, altitude |
| **Location "Always"** (a *second*, later prompt) | `NSLocationAlwaysAndWhenInUseUsageDescription` | Keep updating with the screen locked + resume from parked |
| **Motion & Fitness** | `NSMotionUsageDescription` | Barometer, for smooth/accurate altitude |
| **Live Activities** | (toggle, not a usage string) | Show the Lock Screen / Dynamic Island activity |

### The two-step location flow — and why "Always" matters

iOS **does not let an app request "Always" directly**. The engine first calls
`requestWhenInUseAuthorization()`; once granted it calls
`requestAlwaysAuthorization()`, which is what triggers the *second* "Keep
Allowing Always?" prompt — and iOS often defers that prompt until you've been
using the app for a bit. So expect **two separate prompts, minutes or a session
apart**. (See `start()` in `LocationEngine.swift`.)

**"While Using" is not enough for the core use case.** With only *When In Use*:

- Updates pause when you lock the screen or switch apps, so the Lock Screen
  Live Activity goes stale — defeating the "glance without unlocking" point.
- **Parked → resume is unreliable.** Parking stops location, so iOS suspends and
  may terminate the app. Tapping play relaunches it in the background to run the
  intent, but a background-launched app can only restart location with **Always**
  authorization. With *When In Use*, resume may not relight GPS until you next
  open the app by hand.

So for this app to do what it's for, grant **Always**. If you only see *When In
Use* in Settings, go to **Settings → You Are Here → Location → Always**. The blue
status-bar pill while it's tracking is expected (`showsBackgroundLocationIndicator`).

### Entitlements / capabilities

There is **no `.entitlements` file and no special code-signing entitlement** —
Live Activities and background location are enabled purely through `Info.plist`
keys, so there's nothing to toggle under Signing & Capabilities for them:

- `NSSupportsLiveActivities` + `NSSupportsLiveActivitiesFrequentUpdates`
- `UIBackgroundModes` → `location` (keeps the app alive in the background to
  refresh the activity)

No App Group is used: the Live Activity pause button is a `LiveActivityIntent`
that runs in the app's process and reaches the engine through an in-process
closure, so app/widget don't need shared storage. (If you later add an offline
dataset or want the widget to read settings directly, that's when you'd add an
App Group — and *that* would be a real capability to enable on both targets.)

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
5. On first launch, accept the location prompt, then accept the **second
   "Always"** prompt when it appears (or set **Settings → You Are Here →
   Location → Always**). See *Permissions & entitlements* above for why Always
   matters.

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
design/
  appicon.py                    Regenerates the app icon (run with Pillow)
```

The **app icon** is the app in miniature — grey "YOU / ARE" kicker, big bright
"HERE", and a rough treasure-map red X — on near-black, matching the app's
bright-on-dark skin. It's generated programmatically (so it's tweakable and
diffable) by `design/appicon.py`; re-run it after edits:

```bash
pip install Pillow
python3 design/appicon.py   # rewrites YouAreHere/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```

## Known limitations / next steps

- **Route numbers depend on the data source.** Apple's geocoder has no route-
  number field — it only surfaces a number when the road's *name* is itself the
  route (e.g. it returns "I-80" or "CA-89" as the thoroughfare). For a road Apple
  labels by street name (e.g. "St George Rd", which is also ME-131), Apple gives
  us nothing to show a shield from. Two paths fill this in:
  - **Online lookup (opt-in).** *Settings ▸ Route numbers ▸ Look up online.* When
    Apple gives a plain street name, the app queries OpenStreetMap (Overpass) for
    nearby ways, picks the one whose OSM name matches the geocoded road (nearest
    as tie-break — plain nearest would pin the *previous* road's number to a road
    you just turned onto), and shows its route `ref` as the shield (see
    `RouteRefResolver.swift`, `RoadInfoResolver`). It's **off by default** because
    it sends your coordinate to a third-party server (`overpass-api.de`) and needs
    a network connection — so it won't help in the no-signal areas this app is
    otherwise built for. To stay within Overpass's fair-use limits, it fires
    **only when the road changes** (not every tick), one request at a time, with a
    minimum spacing between calls; failures fall back silently to Apple-only.
  - **Offline dataset (future).** Bundled OSM data would supply route `ref`s with
    no network and work off-grid. `RoadInfoResolver` is a protocol so an offline
    resolver can drop in behind the same seam.
- **Speed limit (opt-in).** *Settings ▸ Speed limit ▸ Show speed limit.* Reads the
  posted limit from OpenStreetMap's `maxspeed` tag and shows a gray "SPEED LIMIT"
  sign at the trailing end of the road row (flashes white on change). There is no
  Apple API for speed limits, so this uses the **same** Overpass road-change
  lookup as route numbers — negligible extra battery. Same caveats: needs network
  and OSM coverage is partial, especially on minor/rural roads (shows nothing when
  unknown). Units follow the Imperial/Metric setting.
- **Route shields are heuristic.** `RouteParser` pattern-matches the route text
  ("I-80", "US Highway 50", "CA-89", "ME 131"); some forms won't match and show
  as a plain name. Shields are stylized, not pixel-accurate MUTCD artwork.
- **Offline naming** isn't implemented yet (see the warning above).
