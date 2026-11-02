# Karta's constitution

The rules this app is held to, and why each one exists.

Every principle here was paid for — it comes from a decision already made in
this codebase, usually after getting it wrong once. None of them are generic
good practice. They are the specific commitments that make Karta this app
rather than a different one, and they are written down so a change can be
checked against them instead of against somebody's memory of a conversation.

When a change conflicts with a principle, the principle does not
automatically win — but the conflict has to be deliberate, argued, and
recorded in the changelog. Silent drift is the thing this document exists to
prevent.

---

## I. A recording is evidence. A route is a plan.

They are different types and they stay different types.

A route is sparse waypoints and routed legs, edited freely, re-routed on
demand. A recording is dense, timestamped, append-only while it runs and
immutable afterwards. GPX draws the same line: `<trk>` for the recorded
thing, `<rte>` for the planned one.

**A recording is never snapped to trail geometry.** The moments worth
recording are exactly the ones snapping erases: the social trail, the bail-out
down a drainage, the twenty minutes lost. Snapping also needs network, in an
app whose point is working without it.

Converting a recording into a route is allowed, but only as an explicit action
the user asks for, producing a separate object. The recording underneath stays
untouched.

---

## II. Never estimate silently.

Where a number is not measured, the app says so, in the number's own
neighbourhood — not in a footnote, a tooltip, or a help page.

- Measured and estimated distance are separate fields, on gain as well as
  distance. They are summed for display, never in storage.
- An estimated line is drawn dashed. The same convention covers a leg with no
  trail and a bridged gap, because it means the same thing in both: this line
  is our guess, not the ground.
- A total that is unreliable says *which way* — unbridged gaps read low, a
  bridge means part of the figure is estimated.
- An estimate is never written into an export where it would become
  indistinguishable from measurement. Bridged gaps are not written as GPX
  `trkpt`s, because once written, no tool anywhere could ever tell them from
  real fixes again.

The corollary: a gap in the data is a value, not an absence. It carries both
ends, a cause, and a duration — which is knowable exactly even when the
distance never will be.

---

## III. Show the seams.

Every provider reports which dataset answered, when, whether it came from
cache, and whether it is stale. The sources panel renders all of it and has a
permanent control, not a buried one.

A number with no origin is a number you cannot debug in the field, and in the
field is the only place it matters. When a source fails, the control turns
accent so a stale answer is visible without opening anything.

---

## IV. Keyless, end to end.

No API key ships in the binary, because a key in an iOS binary is extractable.
No backend exists to hide one behind, and adding one would be a change to what
this app *is*, not a convenience.

Every data source is open: OSM via Overpass, BRouter, USGS 3DEP, Open-Meteo,
Terrarium tiles, CAIC. This is why the Apify trailhead scraper was rejected
even though it would have worked — and the names turned out to be in OSM
already, beside the nodes rather than on them.

---

## V. The field is the deployment target.

Decisions are made for a phone in a pocket, on a mountain, with no bars and a
draining battery.

- **Data that cannot be refetched never lives in Caches.** The cache evicts to
  stay inside a byte budget and iOS can purge it wholesale. Correct for tiles
  and elevation samples, catastrophic for the only copy of a hike. Recordings
  live in Application Support.
- **A recording survives the app dying.** Every accepted fix reaches disk as it
  happens, line-delimited, so a crash costs one fix rather than the hike.
- **Writes are ordered so a failure is recoverable.** The track is written
  before the journal is deleted, never the other way round.
- **A pause stops counting, not the GPS.** Recovering what actually happened
  beats estimating it, and the radio is already on.

---

## VI. The core is pure. The app is a shell.

`RouteBuilderCore` has no UIKit, no MapLibre, no SwiftUI. Route maths, the
providers, the filter, the recorder and the store all live there and run under
`swift test` on macOS in milliseconds, with no simulator boot.

Anything that needs to think goes through `AppModel`. The views are a bridge:
state in, gestures out.

---

## VII. One definition per number.

Two implementations of the same quantity will eventually disagree, and the one
you are not looking at will be the one on screen.

Gain is computed in exactly one place and reused by routes and recordings
alike. A bridge's coordinates feed both its distance and its drawing, so the
dashed line is always exactly as long as the total claims. The scrub cursor
lives on the model because two views show it.

When the same concept appears twice, extract it before the second copy is
written, not after it drifts.

---

## VIII. Verify in the real app, without a finger on the screen.

A change is not done because it compiles and the unit tests pass. It is done
when the chain it belongs to has been exercised in the running app and the
result inspected.

Every feature therefore gets a debug launch flag. This is not a convenience:
`simctl privacy grant location` does not work on the iOS 27 simulator, so a
real recording cannot be scripted at all, and a screenshot cannot tap, drag,
long-press, or answer a prompt. Without flags, whole subsystems would be
unverifiable.

Proof is a screenshot or console output, read before commit — and read
sceptically. A downscaled screenshot is not evidence; sample the pixels when
something looks wrong.

---

## IX. Prove a port against the thing that shipped.

Where Karta ports behaviour from the web app, expected values come from running
the original JavaScript under node, not from recomputing the formula in Swift.

A port that agrees with freshly derived arithmetic proves nothing. One that
agrees with the shipping app proves nobody's mileage changed.

Where the original is wrong, port it faithfully, pin it in a test with a
comment, and leave the decision to change it to a human. A silent "fix" to a
number people have been reading for a year is a worse bug than the bug.

---

## X. The chrome is a field instrument.

Dark, warm, quiet, dense with real numbers. Follows the Field Instrument
token system in `Karta/DesignSystem.swift` — nothing hardcodes a colour,
duration or spacing that exists as a token.

- **Dark chrome over a deliberately light topo basemap, regardless of the
  device setting.** The panels recede and the terrain stays the brightest thing
  on screen. This is the call every serious mapping tool makes.
- **Decision UI is hand-built on a Field surface. Never a system alert.** An
  alert presents in its own window, which does not inherit the forced dark
  scheme, so its text lands on a light material and becomes unreadable. The
  same applies to any other self-presenting system UI.
- **Selected states are fills, not bare borders.** A border alone reads
  identical to a press.
- **The authorities' colours are never tokenized.** EPA AQI bands and CAIC
  danger levels are read by sight by people who know them. They keep their own
  palette.

---

## XI. Modeless gestures beat modes.

A mode can be left armed by accident, and the cost lands on whoever forgot.
Long-press inspects the ground rather than arming an inspect mode. Tap selects
a Discover candidate rather than hovering it, because touch has no hover.

The exception is a gesture that *ends* something, which earns the deliberate
action and a visible label — holding the record button saves the hike, and the
button says so while recording. A long press with no affordance is acceptable
only when nothing is lost by never finding it.

---

## XII. Ask at the moment the answer is known.

A question asked too late is a question nobody can answer. The recovery prompt
appears on resume, while the user still remembers walking that stretch — not at
save time, when there could be three of them to untangle, and not mid-hike,
which interrupts the thing being recorded.

Destructive and irreversible actions ask first; reversible ones do not. Clearing
a route is undoable, so it does not stop to confirm — a dialog on a reversible
action only trains people to click through the ones that matter. Deleting a
recording has no undo behind it, so it asks.

Dismissing a question without answering takes the conservative branch: the one
that adds nothing nobody confirmed.

---

## XIII. Read the headers before believing a thread.

Twice now, "MapLibre Native cannot do that" has been true in the letter and
wrong in the outcome — a different API did the job. The slope overlay ships
because `MLNImageSource` was sitting in the framework headers while a GitHub
thread said there was no raster equivalent.

`grep` the `.framework/Headers` directory before declaring anything blocked.
Genuine dead ends exist — 3D terrain is one — but they are rarer than the
internet suggests.

---

## Deliberate debts

Things known to be wrong or missing, kept on purpose, so nobody "discovers"
them and quietly changes behaviour:

- **The 3 m gain hysteresis only guards one-sided drift.** Oscillating DEM
  noise of ±2 m clears the gate every cycle; the live web app reports 1,312 ft
  of gain over 200 points of dead-flat ground. Ported faithfully and pinned in
  a test. Changing it changes every number the web app has ever shown.
- **No 3D terrain.** MapLibre Native iOS has no `setTerrain`. Hillshade is the
  honest substitute, and the flag is named `hillshadeEnabled` rather than
  promising tilt the platform cannot deliver.
- **Slope, aspect and recorded gain are DEM-derived approximations**, not
  survey data, and the README says so.
- **Routes do not persist.** Only recordings do. A hike survives everything; a
  route you built survives nothing.

---

## Using this

Before committing a change, the questions worth asking:

1. Does any number on screen now come from somewhere the user cannot see?
2. Is anything estimated that does not say it is estimated?
3. Would this survive the app being killed? Losing signal? No network at all?
4. Did the same quantity just get a second implementation?
5. Was it run in the app, or only in tests?
6. If it ported something, was it checked against the thing that shipped?
7. Does it add a key, a backend, or a mode?

A "no" that should be a "yes" is either a fix or a line in the changelog
explaining why not.
