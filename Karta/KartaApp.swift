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
                    .contains(where: { $0 == "-openDiscover" || $0 == "-runDiscover" }),
                openSourcesOnLaunch: ProcessInfo.processInfo.arguments
                    .contains("-showSources")
            )
            .environment(model)
            .task {
                // Outside applyLaunchFlags on purpose: that function is
                // #if DEBUG, and looking for a recording the app was killed
                // during is not a debug affordance — it is the whole point of
                // journalling. It also has to run before anything else
                // touches the journal, or starting a new recording would take
                // the choice away from the user.
                #if DEBUG
                let keepJournal = ProcessInfo.processInfo.arguments
                    .contains("-keepJournal")
                #else
                let keepJournal = false
                #endif
                if !keepJournal { await model.findInterruptedRecording() }
                await model.refreshSavedTracks()
                await applyLaunchFlags(model)
            }
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
///   -showSources     open the data sources panel
///   -simulateRecording      play a synthetic hike with an automatic pause
///   -simulateForgottenPause play one paused through, offering a recovery
///   -stopRecording   stop the simulated recording, filling elevations
///   -dumpRecording   print the recorded track's segments, gaps and stats
///   -dumpTracks      print the recordings saved on disk
///   -keepJournal     skip the interrupted-recording check, leaving the journal
///   -saveInterrupted answer the interrupted-recording prompt with "Save it"
///   -openFirstTrack  open the newest saved recording on the map
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

    // Before the dump, and bypassing CoreLocation entirely: the simulator
    // never grants the location permission headlessly.
    if arguments.contains("-simulateRecording") {
        await model.simulateRecording(forgottenPause: false)
    } else if arguments.contains("-simulateForgottenPause") {
        await model.simulateRecording(forgottenPause: true)
    }

    // Stopping is what fills elevations from the DEM, so gain is zero until
    // this runs — the one part of the chain a screenshot of a live recording
    // cannot show.
    if arguments.contains("-stopRecording") {
        await model.stopRecording()
    }

    if arguments.contains("-dumpRecording") {
        let track = model.recorder.track
        let stats = track.stats
        print("RECORDING: state \(model.recorder.state)")
        print("RECORDING: \(track.segments.count) segment(s), \(track.gaps.count) gap(s), "
              + "\(track.recoveredPointCount) recovered point(s)")
        for (index, gap) in track.gaps.enumerated() {
            print("GAP \(index): \(gap.cause.rawValue) | "
                  + "\(String(format: "%.0f", gap.straightLineM)) m apart | "
                  + "\(String(format: "%.0f", gap.durationS)) s | "
                  + "needsDecision \(gap.needsDecision)")
        }
        if let pending = model.pendingRecovery {
            print("RECOVERY: \(String(format: "%.0f", pending.distanceM)) m over "
                  + "\(String(format: "%.0f", pending.durationS)) s, "
                  + "\(pending.points.count) points")
        }
        print("RECORDING: gain measured \(Int(stats.measuredGainFeet)) ft, "
              + "estimated \(Int(stats.estimatedGainFeet)) ft")
        print("RECORDING: measured \(String(format: "%.2f", stats.measuredMiles)) mi, "
              + "estimated \(String(format: "%.2f", stats.estimatedMiles)) mi, "
              + "moving \(Int(stats.movingSeconds)) s, elapsed \(Int(stats.elapsedSeconds)) s")
        print("RECORDING: spans \(track.spans.map { $0.isEstimated ? "dashed" : "solid" })")
    }

    // The prompt's answers are taps, and a script has no finger.
    if arguments.contains("-saveInterrupted") {
        await model.saveInterrupted()
    }

    // Opening one is a tap on a sheet row, which a screenshot cannot do.
    if arguments.contains("-openFirstTrack"), let first = model.savedTracks.first {
        await model.openTrack(first.id)
    }

    if arguments.contains("-dumpTracks") {
        await model.refreshSavedTracks()
        if let found = model.interrupted {
            print("INTERRUPTED: \(found.name) | "
                  + "\(String(format: "%.2f", found.stats.totalMiles)) mi | "
                  + "\(found.segments.count) segment(s)")
        }
        print("TRACKS: \(model.savedTracks.count) saved")
        for summary in model.savedTracks {
            print("TRACK: \(summary.name) | \(String(format: "%.2f", summary.miles)) mi | "
                  + "\(Int(summary.gainFeet)) ft | \(summary.gapCount) gap(s)")
        }
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
