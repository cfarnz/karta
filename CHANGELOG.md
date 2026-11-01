# Changelog

## Unreleased

### Recording

- **A GPS track filter**, in `RouteBuilderCore/TrackFilter.swift`. A raw
  CoreLocation stream is not a track: standing still, the estimate wanders
  inside its own accuracy circle, and a recorder that accepts every fix
  accumulates miles from a picnic table. Four gates, each with its own
  rejection reason — accuracy, movement, pace, and age.
- The movement gate scales with the accuracy of the fix being judged, rather
  than using one flat threshold. Eighteen metres of apparent movement is real
  from a 5 m fix and indistinguishable from sitting still inside a 20 m one.
  A flat threshold banks the second case and creeps the track forward through
  a lunch stop.
- The accuracy ceiling is 20 m rather than the 10 m of the HERE sample this
  borrows its shape from. 10 m is open-sky GPS; under canopy or in a drainage
  it discards nearly everything and the track simply stops, which reads as a
  bug rather than a filter.
- A pace gate rejects fixes that are far enough away but unreachable in the
  elapsed time. A rejected jump leaves the track end where it was, so the next
  good fix is measured from the last real position instead of from the bad
  one. The default suits walking and running; a ski descent needs it raised,
  and a test says so.
- The cached fix CoreLocation hands over immediately on start is dropped on
  age. It can be yesterday's trailhead, and it would draw the first segment
  across the state.
- Every rejection carries a reason and is counted. "The GPS is bad" and "you
  have not moved" look identical on a frozen distance readout and call for
  opposite responses from the person holding the phone, so the counts belong
  in the sources panel.
- `PassthroughTrackFilter` accepts everything, for a debug overlay that draws
  the raw signal beside the filtered one. The two together are how you tell a
  filter that is too strict from a GPS having a bad day.
- 14 tests, 197 green. The headline pair runs the same 200 readings wandering
  inside a 6 m circle through both filters: the real one records 0 m, the
  passthrough records 758 m of travel that never happened.

- **Recorded tracks are their own type**, in `RouteBuilderCore/Track.swift`.
  `RouteState` is sparse waypoints and routed legs, edited freely. A recording
  is dense, timestamped, append-only while it runs and immutable after,
  because it is evidence of where somebody was. GPX draws the same line: `trk`
  for the recorded thing, `rte` for the planned one. A recording is never
  snapped to OSM geometry — the moments worth recording are exactly the ones
  snapping erases.
- **A gap is a value, not a hole.** The recording stops and starts: a
  forgotten unpause, a drainage with no sky, a killed app. Most trackers answer
  with a break in the line and a total that is quietly short — and that total
  is what you later use to guess how long the hike takes. `TrackGap` carries
  both ends, the cause, and whatever stands in for the missing stretch.
- The asymmetry that shapes the rest of it: **a gap's duration is exact** —
  the timestamps either side are real whether or not anyone knows the path —
  **while its distance can only be estimated**. So moving time and total
  elapsed are both reported, and elapsed, the number that answers "how long
  does this take", survives a forgotten pause intact.
- Measured and estimated distance are kept apart rather than summed into one
  figure, on gain as well as distance. A bridge can be a straight line (a
  floor: nobody walks the chord) or a routed path between the ends (the better
  guess when both ends are on trail), and either way it draws dashed — the
  same convention already used for a leg with no trail, meaning the same
  thing: this line is our guess, not the ground.
- Gain is summed per segment rather than over one stitched list, so the
  elevation step across a gap is never banked as climb. Reappearing 300 m
  higher after a signal loss used to be worth 1,000 ft of phantom gain.
- `looksLikeForgottenPause` and `gapsNeedingDecision` name the case the user
  can resolve and the app can only infer. The prompt belongs at save time, not
  mid-hike: stopping to ask interrupts the thing being recorded, and saving is
  the last moment they still remember what happened.
- A gap smaller than the track filter's own movement floor is not worth
  asking about — below that the recorder could not tell motion from noise, so
  bridging it would add distance nobody walked. The rest still shows up as
  time.
- **GPX writes one `trkseg` per unbroken run of recording**, which is what the
  spec has segments for and how a pause survives into Gaia or COROS instead of
  being flattened into a line through the gap. Bridged gaps are deliberately
  not written as track points: an estimate written as a `trkpt` is
  indistinguishable from measured GPS forever after, in this app and every
  other one. Track points also carry a UTC `time`; the planned-route export is
  untouched.
- The gain rule moved to `RouteState.gainM(for:)` so a track reuses the
  identical hysteresis per segment. Gain is the number in this app least able
  to afford two copies of its own definition.

Nothing in the app calls any of this yet — there is no recording session, and
background GPS is still ahead. These are the pieces that session will need,
and they landed with no project-file changes. Two preventative layers belong
with the session itself: keeping the GPS running during a pause so a forgotten
unpause can be recovered rather than estimated, and auto-pausing off the
filter's own run of stationary rejections so the user is not the one who has
to remember.

## 0.1.0 — 31 October 2026

First working build of the native iOS port. The app draws real routes on real
trails, reads the ground under any point, and finds loops near you.

### Design

- The Field Instrument design pass. `DesignSystem.swift` ports Clay's
  `tokens.css` to Swift: warm dark neutrals, one accent, semantic colours used
  only for meaning, a six-step type scale with size-specific tracking, a 4pt
  space scale, and motion curves under 300ms. Nothing hardcodes a colour,
  duration or spacing that exists as a token.
- Dark chrome over a deliberately light topo basemap, fixed regardless of the
  device setting. The panels recede and the terrain stays the brightest thing
  on screen.
- Every measurement is mono and tabular, with its unit riding along dimmed and
  smaller, so digits do not reflow while a value changes under your finger.
- **A sources panel.** Every provider already reported which dataset answered,
  how old it was and whether it came from cache, and nothing displayed any of
  it. Each row now carries a coloured stripe for live, cached, stale or
  failed. The control itself turns accent when any source is stale, so a bad
  source is visible without opening the panel.
- Selected states are fills rather than bare borders, which read the same as a
  press and made the Discover list hard to scan.
- Difficulty badges moved onto the semantic colours instead of an invented
  scale, and press feedback is now on pointer-down rather than release.

- **App icon.** Contour rings fading from the accent at the summit to warm
  grey at the outside, on the same warm dark ground as the app chrome. The
  gradient is what carries it at small sizes: a single flat colour reads as a
  fingerprint at 60pt. Added as an asset catalog, which the project did not
  have at all before, so builds were shipping the blank default.

### Route building

- Tap-to-add waypoints, snapped to trails by BRouter's `hiking-mountain`
  profile. Legs with no trail fall back to a straight line and are drawn
  dashed rather than passed off as a path.
- Draggable markers. A middle waypoint rebuilds the legs on both sides
  concurrently, so the drag costs one round trip rather than two. Results that
  land out of order against a changed route are discarded instead of applied.
- Live distance and climbing, with undo.
- Two basemaps, OpenTopoMap and USGS The National Map.

### Terrain

- **Slope and aspect overlays**, computed on device from Terrarium DEM tiles
  via `MLNImageSource`. Tiles are stitched before slope is computed, which
  removes the one-pixel seam the web app left on every tile boundary, and cell
  size follows the Mercator stretch per row rather than per tile.
- **Hillshade** from the same DEM using Igor's method, chosen because it is the
  one that tries not to bury the contour lines underneath it.

### Elevation profile

- Swift Charts profile with drag-to-scrub. The readout, the chart cursor and a
  marker on the map all follow one shared value.
- The scrub converts through `ChartProxy` rather than a fraction of the plot
  width, fixing a web app quirk where the cursor sat slightly off near either
  edge, and the nearest-point lookup binary searches the monotonic distances
  instead of scanning every point on every frame.

### Location card

- Long-press any point for elevation, slope and aspect, weather and a three-day
  forecast, US AQI with a smoke trend, active NWS alerts, and the CAIC
  avalanche zone.
- Five providers in parallel; a failure omits its section rather than failing
  the card.
- Long-press replaces the web app's "Inspect a point" mode button. A mode can
  be left armed by accident, which matters when a plain tap adds a waypoint.

### Discover

- Loop generation from nearby trailheads, sized to a target distance and
  filtered by difficulty, high point and search radius, with a determinate
  progress bar over a search that can take half a minute.
- Hover-to-preview became tap-to-select, since a touch screen has no hover. The
  sheet sits at a medium detent with background interaction on, so the map it
  is previewing onto stays visible.
- Loading a result re-routes its via points so the route is editable rather
  than frozen, and takes a single undo snapshot for the whole set.
- **Real trailhead names.** About a third of OSM trailhead nodes near Boulder
  carry no name, and some carry GPS-import labels like `Gen10` that look
  deliberate. Names are resolved from nearby trails and protected areas in one
  extra Overpass pass — the `Gen06`..`Gen13` cluster turns out to sit inside
  Genesee Mountain Park. Eight of eight anchors near Boulder now carry real
  names.

### Foundations

- `RouteBuilderCore`, a dependency-free Swift package holding all logic, with
  the app as a thin shell. Tests run on macOS in milliseconds with no
  simulator.
- Dual elevation providers: USGS 3DEP at 1 m inside its coverage, Open-Meteo at
  90 m elsewhere, with the resolver reporting which answered.
- Disk cache with per-source TTLs and stale-on-failure fallback.
- GPX 1.1 serialisation with elevations, so COROS and Gaia show a real profile.
  No export UI yet.
- **183 tests in 31 suites**, asserted against values generated by running the
  original JavaScript under node rather than re-derived in Swift.

### Known issues

- No 3D terrain: MapLibre Native iOS does not ship it, and hillshade is the
  substitute.
- Elevation gain over-reports on flat ground. The 3 m hysteresis guards
  one-sided drift but not oscillation, so ±2 m DEM noise clears it every cycle.
  Matches the web app exactly, on purpose, and is pinned by a test.
- Discover's first search in a new area is slower now that trailhead naming
  adds an Overpass round trip. It is cached for a week and only runs when a
  name is actually missing.
