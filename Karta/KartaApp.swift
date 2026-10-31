import SwiftUI
import RouteBuilderCore

@main
struct KartaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(
                // Debug only; the real sheet is opened from the toolbar.
                openDiscoverOnLaunch: ProcessInfo.processInfo.arguments
                    .contains(where: { $0 == "-openDiscover" || $0 == "-runDiscover" })
            )
            .environment(model)
            .task { await applyLaunchFlags(model) }
        }
    }
}

/// Debug launch flags, each independent of the others:
///
///   -seedDemoRoute   two waypoints on a known Boulder trail
///   -useUSGS         start on the USGS basemap
///   -hillshade       turn on shaded relief
///   -slopeOverlay    turn on slope shading
///   -aspectOverlay   turn on aspect shading
///   -scrubAt <0..1>  park the profile cursor partway along the route
///   -openDiscover    present the Discover sheet on launch
///   -runDiscover     present it and start a search straight away
///   -skipLocation    report no location fix, so Discover uses the map centre
///   -previewFirst    select the top result, drawing its preview on the map
///   -loadFirst       load the top result into the builder
///   -inspectAt <lon,lat>  open the location card on a point
///   -dumpNames       print the discovered route names to stdout
///   -dumpTrailheads  print the trailheads found near Boulder, with names
///
/// They exist because the whole chain — BRouter, the elevation providers, the
/// Terrarium tiles — is otherwise only reachable by tapping the screen, which
/// a screenshot cannot do.
@MainActor
private func applyLaunchFlags(_ model: AppModel) async {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments

    if arguments.contains("-useUSGS") {
        model.basemap = .usgs
    }
    if arguments.contains("-hillshade") {
        model.hillshadeEnabled = true
    }
    if arguments.contains("-slopeOverlay") {
        model.terrainOverlay = .slope
    } else if arguments.contains("-aspectOverlay") {
        model.terrainOverlay = .aspect
    }

    if arguments.contains("-seedDemoRoute") {
        // Chautauqua trailhead to the Royal Arch area.
        await model.addWaypoint(Coordinate(longitude: -105.2811, latitude: 39.9992))
        await model.addWaypoint(Coordinate(longitude: -105.2928, latitude: 39.9865))
    }

    // After the route, not before: building a route clears the cursor,
    // because a cursor placed on an old track points at nothing.
    if arguments.contains("-runDiscover") {
        // The sheet reads the map centre through a binding the map fills in,
        // so this goes straight to the model with Boulder as the fallback.
        await model.runDiscover(
            mapCenter: Coordinate(longitude: -105.28, latitude: 39.995))
    }

    if arguments.contains("-dumpTrailheads") {
        // Isolates the naming change: Discover's own filters discard most
        // anchors, so the candidate list is a poor view of what was found.
        let found = await model.discover.findTrailheads(
            center: Coordinate(longitude: -105.28, latitude: 39.995),
            radiusMiles: 20, limit: 8)
        for trailhead in found.trailheads {
            print("TRAILHEAD: \(trailhead.name) | "
                  + "\(String(format: "%.1f", trailhead.distanceFromCenterM / 1609.344)) mi")
        }
    }

    if arguments.contains("-dumpNames") {
        // Results live below the fold of a medium-detent sheet, and a
        // screenshot cannot scroll. Printing them is the only way to assert
        // on the actual strings.
        for candidate in model.candidates {
            print("CANDIDATE: \(candidate.name) | "
                  + "\(String(format: "%.1f", candidate.distanceMiles)) mi")
        }
    }

    if let first = model.candidates.first {
        if arguments.contains("-loadFirst") {
            await model.load(first)
        } else if arguments.contains("-previewFirst") {
            model.previewedCandidate = first
        }
    }

    if let flag = arguments.firstIndex(of: "-inspectAt"),
       arguments.index(after: flag) < arguments.endIndex {
        let parts = arguments[arguments.index(after: flag)]
            .split(separator: ",").compactMap { Double($0) }
        if parts.count == 2 {
            await model.inspect(at: Coordinate(longitude: parts[0], latitude: parts[1]))
        }
    }

    if let flag = arguments.firstIndex(of: "-scrubAt"),
       arguments.index(after: flag) < arguments.endIndex,
       let fraction = Double(arguments[arguments.index(after: flag)]) {
        model.cursor = model.profile.point(atFraction: fraction)
    }
    #endif
}
