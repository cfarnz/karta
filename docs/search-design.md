# Place search for Discover — design note

Status: **not built.** Written 31 October 2026 after testing the providers
live. Nothing here is committed to; it exists so the work can start without
redoing the research.

## The gap

Discover's centre can only be the GPS fix or whatever the map happens to be
showing. There is no way to ask for loops near a place you are not standing
in, so planning a Telluride or Gore Range trip from Denver means panning the
map across the state by hand.

Neither the web app nor the iOS port ever had place search, so this is a
missing feature rather than something lost in the port.

## What it should do

A search field that resolves a place and then **anchors Discover to it**, so
the radius control reads "within 20 mi of Telluride" rather than "of me". The
map moves there; the existing flow is unchanged from that point on.

That is the whole feature. Searching trailheads by name, and remembering
recent places, are separate and can come later.

## Provider

Keyless is a hard constraint: the app ships no secrets and has no backend,
which is why there is nothing to operate or rotate. That rules out the
commercial geocoders.

Tested live on 31 October:

| Provider | Verdict |
| --- | --- |
| **Photon** (komoot, OSM) | Best fit. Keyless, built for type-ahead, supports proximity bias and tag filters. |
| Nominatim (OSM) | Works, but ranked *Brainard Lake, Alberta* above the Colorado one, and its usage policy effectively forbids per-keystroke queries. |
| Apple `MKLocalSearch` | Best ranking and free, but Apple's Maps terms restrict using MapKit-derived data alongside a non-Apple map, and this app renders with MapLibre. **Unverified — read the actual clause before choosing this.** |

Photon is also the consistent choice: trailheads already come from OSM via
Overpass, so search and data would agree about what exists.

## The ranking trap

Proximity bias alone is actively wrong for the use case. Biased to Boulder:

| Query | Naive | With `osm_tag=!highway` |
| --- | --- | --- |
| Telluride | *Telluride Lane, Boulder* | **Telluride, San Miguel County** |
| Gore Range | *Gore Range Court, Jefferson* | Gore Range Overlook |
| Mount Sanitas | — | **natural:peak** |
| Brainard Lake | Brainard Lake, Boulder County | Brainard Lake, Boulder County |

Searching "Telluride" from Boulder returns a residential cul-de-sac, because
the bias beats the importance ranking. Excluding `highway` fixes it, and costs
nothing: a trail app essentially never wants a street.

Bias should come from the **map view**, not the user's GPS fix. Someone
looking at the San Juans wants results there, not near home.

## Known weak spot

"Gore Range" does not resolve to the range itself, only to a viewpoint and a
parking area named after it. Large natural features are often OSM relations
that Photon does not surface well. Worth checking against a handful of real
targets (Indian Peaks, Sawatch, Never Summer) before deciding whether it
matters.

## Open questions

- Photon's public instance is free for reasonable use. Confirm its terms and
  rate expectations before shipping type-ahead, and debounce keystrokes
  regardless. Self-hosting exists as a fallback but would mean a backend,
  which the app deliberately does not have.
- Search needs the network. Decide what it does with no signal: recent places
  would still work offline and may be the honest answer.
- Results should carry provenance like everything else, so the sources panel
  can say the search came from Photon and when.

## Rough shape

1. `PlaceSearch` in `RouteBuilderCore` — query building, tag filters, result
   ranking and decoding, behind the existing `HTTPFetching` seam so it is
   testable offline. Ground truth from the live queries above.
2. A search field in the Discover sheet, debounced, writing the chosen place
   into `DiscoverSettings` as an explicit centre that overrides the fix.
3. The radius label changes to name the place, so it is obvious what the
   search is anchored to.
