# Karta

A native iOS trail route builder. Draw a route on a topo map, snap it to real
trails, read the ground under any point, and find loops near you.

Karta is a native SwiftUI rewrite of [route-builder][web], a vanilla
JavaScript web app. The rewrite exists for three things the web could not do:
offline map tiles, background GPS, and working with no signal. Everything else
— the route math, the dual elevation providers, the cache, GPX — ports across
or improves.

[web]: https://cfarnz.github.io/route-builder

**Status:** 0.1, in active development. Not on the App Store.

---

## What it does

**Build a route.** Tap the map to drop waypoints. [BRouter][brouter] snaps each
leg to a real trail with a hiking profile; where there is no trail, the leg
falls back to a straight line and says so. Markers drag, legs rebuild, and the
distance and climbing update live.

**Read the terrain.** Slope and aspect overlays are computed on device from
[Terrarium][terrarium] DEM tiles — no slope tile service exists to point at.
Shaded relief comes from MapLibre's hillshade layer using Igor's method, which
is the one that tries not to bury the contour lines underneath it.

**See the climbing.** A Swift Charts elevation profile under the map, with
drag-to-scrub: the readout, a cursor on the chart, and a marker on the ground
all track your finger.

**Inspect any point.** Long-press to get elevation, slope and aspect, current
weather and a three-day forecast, US AQI with a smoke trend, active NWS alerts,
and the CAIC avalanche zone — five providers in parallel, each failure
degrading to an omitted section rather than a failed card.

**Find something to do.** Discover generates candidate loops from trailheads
near you, sized to a target distance and filtered by difficulty, high point and
drive time. Tap a result to preview it on the map, then load it into the
builder as an editable route.

[brouter]: https://brouter.de
[terrarium]: https://registry.opendata.aws/terrain-tiles/

---

## Architecture

```
RouteBuilderCore/   a dependency-free Swift package — all the logic
Karta/              a thin SwiftUI + MapLibre shell on top
```

`RouteBuilderCore` imports no UIKit, no SwiftUI and no MapLibre. Every provider
talks to the network through one `HTTPFetching` protocol, so the route math,
the elevation resolver, the router, Discover and the location summary are all
testable offline with canned responses. The suite runs under `swift test` on
macOS in about 15 ms with no simulator boot.

That split is the main structural improvement over the web app, where the logic
and the `fetch` calls were the same lines — which is why none of its provider
behaviour was ever covered by a test.

### How the port was validated

Ground truth came from **running the original JavaScript under node** and
asserting the Swift against those numbers. A port that only agrees with freshly
derived arithmetic proves the Swift is self-consistent; agreeing with the
shipping web app proves nobody's mileage, gain, slope angle or AQI band
changed.

**252 tests in 35 suites.**

---

## Data sources

Every source is keyless and public. Karta ships no secrets and needs no
backend, which is a deliberate constraint — it is why there is nothing to
operate and nothing to rotate.

| What | Source |
|---|---|
| Basemaps | OpenTopoMap, USGS The National Map |
| Elevation (fine) | USGS 3DEP EPQS — 1 m, US only |
| Elevation (coarse) | Open-Meteo — 90 m, worldwide fallback |
| DEM tiles | AWS Terrain Tiles (Terrarium encoding) |
| Routing | BRouter, `hiking-mountain` profile |
| Trailheads | OpenStreetMap via Overpass |
| Weather, air quality | Open-Meteo (forecast and CAMS) |
| Alerts | NWS |
| Avalanche | CAIC via avalanche.org |

Responses are cached on disk with per-source TTLs, from 15 minutes for alerts
to a year for elevation, since terrain does not move. A fetch that fails with
something already cached returns the stale value and says how old it is, rather
than failing — the behaviour that matters most on a ridge with one bar.

---

## Build and run

Requires Xcode with an iOS 26 SDK. MapLibre Native 7.0.0 resolves through SPM.

```sh
./run.sh                 # release build, boot a simulator, install, launch
./run.sh --debug
./run.sh -seedDemoRoute -hillshade
```

Run the logic tests without a simulator:

```sh
cd RouteBuilderCore && swift test
```

### Debug launch flags

The whole chain is otherwise only reachable by tapping the screen, which a
screenshot cannot do. Each flag is independent.

| Flag | Effect |
|---|---|
| `-seedDemoRoute` | two waypoints on a known Boulder trail |
| `-useUSGS` | start on the USGS basemap |
| `-hillshade` | shaded relief on |
| `-slopeOverlay` / `-aspectOverlay` | terrain shading on |
| `-scrubAt <0..1>` | park the profile cursor partway along the route |
| `-openDiscover` / `-runDiscover` | open Discover, optionally searching |
| `-skipLocation` | report no fix, so Discover uses the map centre |
| `-previewFirst` / `-loadFirst` | select or load the top result |
| `-inspectAt <lon,lat>` | open the location card on a point |
| `-dumpNames` / `-dumpTrailheads` | print results to stdout |

---

## Known limitations

**No 3D terrain.** MapLibre Native iOS has no `MLNTerrain` and no `setTerrain`
in any of its headers; the MapLibre project lists Terrain3D as an unshipped
roadmap item still seeking co-funding. Hillshade is the honest substitute — no
tilt, but the relief reads.

**Elevation gain is noisy on flat ground.** Gain uses a 3 m hysteresis to
suppress DEM noise, but it only guards one-sided drift: oscillating noise of
±2 m is 4 m peak to peak and clears the gate every cycle. The web app reports
1,312 ft of gain across 200 points of dead-flat ground, and this port
deliberately reports the same number so the two agree. Pinned in a test that
documents the behaviour for whenever it gets revisited.

**Slope and aspect are approximate.** Both are derived from a DEM, and the
card says which provider and what resolution produced each number. A slope
angle read off a 90 m grid and one off 1 m lidar are different claims.

**Not an avalanche forecast.** Karta shows reference data from automated
sources. CAIC's own bulletin and your own field observations are the thing to
act on.

---

## Not built yet

Saved routes — only recordings persist, so a hike survives everything and a
route you built survives nothing. Offline tile caching is the last of the
three native-only features that motivated the rewrite; background GPS and
working with no signal both landed with recording.

---

## How decisions get made

[docs/constitution.md](docs/constitution.md) is the set of rules this app is
held to and the reasoning behind each one — why a recording is never snapped
to a trail, why an estimate is never silent, why nothing ships with an API
key. Every principle in it was paid for by a decision already made here. It is
the first thing to read before changing behaviour, and the place to record a
deliberate departure.
