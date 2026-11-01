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

### The recording session

- **Recording works end to end.** `TrackRecorder` in the core is the state
  machine — idle, recording, paused, stopped — with the track filter in front
  of it and a `Track` behind it. `LocationStreamProvider` bridges CoreLocation
  into an `AsyncStream`, and the app gets a record control, a live readout and
  a recovery prompt.
- **A pause stops counting, not the GPS.** Fixes keep arriving into a shadow
  buffer while paused. So the forgotten unpause — pause at a creek, walk on,
  remember twenty minutes later — is *recovered* rather than estimated: on
  resume the app has the actual path and asks whether to include it. Accepting
  adds measured points to the same segment, so no gap exists at all. Nothing
  was missing; it was only set aside.
- The buffer uses the same filter as the live track, not a coarser one. The
  cost of recording through a pause is the radio, which is already paid the
  moment the stream stays up; thinning the points saves memory nobody is short
  of and loses the fidelity that made recovery better than estimating. A
  coarse 50 m gate measured a 276 m stretch as 184 m — an estimate wearing a
  measurement's clothes.
- **The recorder pauses itself** after two minutes without an accepted fix,
  and resumes itself on movement, splicing the buffered stretch back without
  asking. Human error mostly disappears when the human is not in the loop, and
  the recorder paused itself off a guess, so reversing that guess is its own
  job. A manual pause never ends itself, however far the user walks.
- The threshold is measured from the last accepted fix rather than counted in
  fixes, so it behaves the same whether they arrive every second or every half
  minute.
- The recovery prompt appears at resume — the moment the answer is known and
  still remembered — and says the distance measured from the pause point, so
  the number in the question equals what accepting adds. Dismissing without
  choosing leaves the gap, which adds nothing nobody confirmed.
- **CoreLocation's own `pausesLocationUpdatesAutomatically` is off.** It
  decides for itself that you have stopped and silently stops delivering, with
  no event saying so — a direct cause of the gap this feature exists to avoid.
  Karta pauses itself, visibly, off a rule it can explain. Every location in a
  delivered batch is used, not just the newest: iOS hands over a backlog after
  a processing gap, and those are real fixes from the stretch that was missed.
- **Elevations are filled from the DEM when a recording stops**, not taken
  from GPS altitude. Vertical GPS noise summed over a hike is mostly noise —
  the vertical version of the problem the track filter solves horizontally.
  Sampling the recorded line makes a recorded hike's gain comparable with a
  planned route's, and the sources panel says where it came from.
- Background location is declared, so a recording survives the screen locking
  and the phone going in a pocket, which is where a trail app spends most of
  its life.
- The recording draws green over the route's orange — a recording is not a
  plan and the two must not be confused — with bridged gaps dashed, as one
  source and two layers split by a predicate. The map frames the recording on
  its first accepted fix, once rather than continuously: a map that follows
  every fix cannot be panned away from to look at the ridge ahead.
- Recording takes the map. Taps no longer add waypoints and the route-editing
  controls are hidden rather than left enabled and inert; terrain and sources
  stay, because reading the ground mid-hike is the point of having them. Long
  press still opens the location card.
- The recovery prompt is hand-built rather than a `.alert`. A system alert
  presents in its own window, which does not inherit the app's
  `preferredColorScheme`, so dark-scheme type landed on a light material and
  the whole thing read as orange and grey on grey — unreadable. It is now a
  Field surface with Field tokens, which also lets the two numbers that are
  the entire decision be readouts rather than prose.
- `-simulateRecording`, `-simulateForgottenPause`, `-stopRecording` and
  `-dumpRecording` drive the whole chain with synthetic fixes. Not a
  convenience: `simctl privacy grant location` does not take on the iOS 27
  simulator, so the permission alert blocks every headless run and a real
  recording cannot be scripted at all.

### Saved recordings

- **Recordings survive the app dying.** The requirement was never "save the
  track when the user taps stop" — it was "the phone died four hours into a
  hike". Each accepted fix is appended to a journal as it happens, one JSON
  object per line, and only becomes a finished track at the end. A crash
  leaves a journal; the next launch finds it and offers the hike back with
  three answers: keep recording, save it, discard.
- Carrying on from a recovered journal marks a `terminated` gap first, so the
  line never runs straight through the part the phone was off for.
- Line-delimited on purpose: a half-written final line is the expected shape
  of a crash, and replay drops that one line rather than the hike.
- **Not in the Caches directory.** `ProviderCache` lives there and evicts the
  oldest files to stay inside a byte budget, and iOS may purge the whole
  directory under storage pressure. Both are right for tiles and elevation
  samples, which can be fetched again, and catastrophic for the only copy of
  somebody's hike.
- Saving writes the track and then drops the journal, in that order. A failed
  write leaves the journal, so the next launch still offers the hike;
  deleting first would lose it on the one path that is meant to be safe.
- Each track is written beside a small summary file, so the list shows
  distance, gain and gap count without decoding a few thousand points per row.
- **Tapping a recording opens it on the map**, framed, with its own stats bar
  and its elevation profile in the chart. Read-only: a recording is evidence
  and the app has no story for editing one. The route underneath is left
  alone rather than replaced, so closing the recording puts you back where
  you were.
- The bar names which way the total is unreliable rather than only that it
  is: unbridged gaps mean it reads low, a bridge means part of it is
  estimated. Deleting the open recording closes it first, so the map cannot
  keep drawing a hike that no longer exists.
- The profile follows the drawn line, bridges included, so the chart and the
  map agree about where a given distance falls. An unbridged gap is a jump in
  both, which is the honest reading of one.
- GPX export from the recordings list, written to a real file so it arrives
  in Mail as something Gaia and COROS can open rather than as pasted text.
  Deleting asks first — it is the one irreversible thing in the app, with no
  undo stack behind it.

### Controls

- **One floating button that changes purpose: tap toggles running and paused,
  hold saves.** It floats over the map rather than sitting in the control row,
  because it is the only control whose job changes with the state of the app.
  The split is what keeps it to one button: a manual pause deliberately never
  ends itself, so resume has to exist, and here resume is simply tapping
  again. The terminal action gets the deliberate gesture, which is also the
  right weight for it — ending a hike by brushing a button is the mistake
  worth designing against. HOLD TO SAVE is spelled out while recording, since
  a long press has no affordance and this one ends the hike.
- The control row had outgrown its width. Recordings, undo and clear moved
  into an overflow menu; the basemap picker, terrain, Discover and sources
  stay visible, because provenance being permanently visible was a deliberate
  call and burying it would undo it.

Saved routes still do not exist — only recordings persist.

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
