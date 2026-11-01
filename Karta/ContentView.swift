import SwiftUI
import RouteBuilderCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Debug only, so a screenshot can see a sheet that is otherwise only
    /// reachable by tapping.
    var openDiscoverOnLaunch = false
    var openSourcesOnLaunch = false
    @State private var showDiscover = false
    @State private var showSources = false
    @State private var showTracks = false
    /// Filled in by the map so Discover can fall back to what is on screen
    /// when there is no location fix.
    @State private var mapCenter: () -> Coordinate = {
        Coordinate(longitude: -105.28, latitude: 39.995)
    }

    var body: some View {
        ZStack(alignment: .top) {
            MapView(route: model.route,
                    basemap: model.basemap,
                    hillshade: model.hillshadeEnabled,
                    terrainOverlay: model.terrainOverlay,
                    cursor: model.cursor?.coordinate,
                    preview: model.previewedCandidate?.coordinates,
                    recordedSpans: model.recordedSpans,
                    fit: model.pendingFit,
                    centerProvider: $mapCenter)
                .ignoresSafeArea()

            VStack(spacing: Field.Space.x2) {
                // The recording owns the readout while it runs: its numbers
                // are the ones being changed, and showing both invites
                // reading the wrong one.
                if model.isRecording {
                    recordingBar
                } else {
                    statsBar
                }
                if let overlay = model.terrainOverlay {
                    legend(for: overlay)
                }
            }
            .padding(.horizontal, Field.Space.x3)

            if let stretch = model.pendingRecovery {
                recoveryPrompt(stretch)
            } else if let interrupted = model.interrupted {
                interruptedPrompt(interrupted)
            }
        }
        .overlay(alignment: .bottomTrailing) { recordControl }
        // The inspection card. Driven off the point rather than a separate
        // flag, so there is one thing to clear when it closes.
        .sheet(isPresented: Binding(
            get: { model.inspectedPoint != nil },
            set: { if !$0 { model.closeInspection() } }
        )) {
            if let point = model.inspectedPoint {
                LocationCardView(point: point,
                                 summary: model.inspection,
                                 isLoading: model.isInspecting)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationBackground(Field.bg1)
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverSheet(mapCenter: mapCenter)
                .environment(model)
                // Medium by default and the map left interactive behind it:
                // the sheet drives a preview on that map, so burying it
                // would hide the thing being previewed.
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationBackground(Field.bg1)
        }
        .sheet(isPresented: $showTracks) {
            TracksSheet()
                .environment(model)
                .presentationDetents([.medium, .large])
                .presentationBackground(Field.bg1)
        }
        .sheet(isPresented: $showSources) {
            SourcesSheet(records: model.provenance)
                .presentationDetents([.medium])
                .presentationBackground(Field.bg1)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Field.Space.x2) {
                // Only once there is a line to plot. An empty chart is a box
                // of axes taking a third of the map for nothing.
                if !model.profile.isEmpty {
                    ProfileView(profile: model.profile,
                                cursor: Binding(get: { model.cursor },
                                                set: { model.cursor = $0 }))
                    .padding(.horizontal, Field.Space.x3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controls
            }
            .animation(Field.drawer(), value: model.profile.isEmpty)
        }
        .task {
            if openDiscoverOnLaunch { showDiscover = true }
            if openSourcesOnLaunch { showSources = true }
        }
        .task(id: model.route.waypoints.count) {
            // Terrain is re-fetchable, so flushing opportunistically costs
            // nothing and keeps the point cache from living only in memory.
            await model.flushCaches()
        }
        // The chrome is a dark instrument over a light map, whatever the
        // device is set to.
        .preferredColorScheme(.dark)
        .tint(Field.accent)
    }

    // ---------- recording ----------

    private var recordingBar: some View {
        HStack(spacing: Field.Space.x4) {
            VStack(alignment: .leading, spacing: 1) {
                FieldLabel(recordingLabel)
                Readout(value: String(format: "%.2f", model.recordingStats.totalMiles),
                        unit: "mi", size: 20)
            }

            Divider().frame(height: 26).overlay(Field.line)

            VStack(alignment: .leading, spacing: 1) {
                FieldLabel("ELAPSED")
                Readout(value: duration(model.recordingStats.elapsedSeconds),
                        unit: "", size: 20)
            }

            Divider().frame(height: 26).overlay(Field.line)

            VStack(alignment: .leading, spacing: 1) {
                FieldLabel("GAIN")
                Readout(value: String(format: "%.0f", model.recordingStats.totalGainFeet),
                        unit: "ft", size: 20)
            }

            if model.isFinishingRecording {
                Divider().frame(height: 26).overlay(Field.line)
                ProgressView().controlSize(.small).tint(Field.accent)
            }
        }
        .padding(.horizontal, Field.Space.x4)
        .padding(.vertical, Field.Space.x3)
        .fieldOverlay()
        .overlay(alignment: .bottomLeading) {
            // Said out loud rather than inferred from a dimmed number: an
            // estimate inside a total is exactly the thing that should never
            // be silent.
            if model.recordingStats.hasEstimate {
                Text("includes \(distance(model.recordingStats.estimatedMiles * Units.metersPerMile)) estimated")
                    .font(.system(size: 9))
                    .foregroundStyle(Field.textFaint)
                    .padding(.leading, Field.Space.x4)
                    .padding(.bottom, 2)
            }
        }
    }

    /// Asked at resume, which is the moment the answer is known and still
    /// remembered. Not mid-hike on a timer, and not at save time either — by
    /// then there could be three of these to untangle.
    ///
    /// Hand-built rather than a `.alert`. A system alert presents in its own
    /// window, which does not inherit the app's `preferredColorScheme`, so
    /// dark-scheme type landed on a light material and the whole thing read
    /// as orange and grey on grey. Everything here is a Field token on a
    /// Field surface, which also lets the two numbers be readouts rather than
    /// prose — they are the whole decision.
    private func recoveryPrompt(_ stretch: RecoveredStretch) -> some View {
        ZStack {
            // Tapping away leaves the gap: the conservative answer, because
            // it adds nothing nobody confirmed.
            Field.bg0.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture { model.discardRecovery() }

            VStack(alignment: .leading, spacing: Field.Space.x3) {
                Text("Moved while paused")
                    .font(.system(size: Field.Size.lg, weight: .semibold))
                    .foregroundStyle(Field.text)

                HStack(spacing: Field.Space.x4) {
                    VStack(alignment: .leading, spacing: 1) {
                        FieldLabel("DISTANCE")
                        Readout(value: distance(stretch.distanceM), unit: "", size: 20)
                    }
                    Divider().frame(height: 26).overlay(Field.line)
                    VStack(alignment: .leading, spacing: 1) {
                        FieldLabel("PAUSED FOR")
                        Readout(value: duration(stretch.durationS), unit: "", size: 20)
                    }
                }

                Text("These points were measured, not estimated. Including them "
                     + "adds them to the track; leaving a gap records that the "
                     + "stretch is unknown.")
                    .font(.system(size: Field.Size.sm))
                    .foregroundStyle(Field.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Field.Space.x2) {
                    Button("Leave a gap") { model.discardRecovery() }
                        .buttonStyle(.field)
                    Spacer()
                    // Prominent because it is the likely answer: the points
                    // are real, and the user usually did walk that stretch.
                    Button("Include it") { Task { await model.acceptRecoveryAndJournal() } }
                        .buttonStyle(.fieldProminent)
                }
            }
            .padding(Field.Space.x4)
            .fieldSurface()
            .padding(.horizontal, Field.Space.x6)
        }
        .transition(.opacity)
    }

    /// Offered at launch when the app was killed mid-recording.
    ///
    /// Three answers rather than two, because "carry on" is a real one: the
    /// usual reason to be looking at this screen is that the phone died in a
    /// pocket and the hike is still happening.
    private func interruptedPrompt(_ track: Track) -> some View {
        ZStack {
            Field.bg0.opacity(0.72).ignoresSafeArea()

            VStack(alignment: .leading, spacing: Field.Space.x3) {
                Text("Recording interrupted")
                    .font(.system(size: Field.Size.lg, weight: .semibold))
                    .foregroundStyle(Field.text)

                HStack(spacing: Field.Space.x4) {
                    VStack(alignment: .leading, spacing: 1) {
                        FieldLabel("RECOVERED")
                        Readout(value: String(format: "%.2f", track.stats.totalMiles),
                                unit: "mi", size: 20)
                    }
                    Divider().frame(height: 26).overlay(Field.line)
                    VStack(alignment: .leading, spacing: 1) {
                        FieldLabel("ELAPSED")
                        Readout(value: duration(track.stats.elapsedSeconds),
                                unit: "", size: 20)
                    }
                }

                Text("Karta closed while this was recording. Everything up to "
                     + "that moment was saved as it happened. Carrying on "
                     + "leaves a gap for the part the phone was off for.")
                    .font(.system(size: Field.Size.sm))
                    .foregroundStyle(Field.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Field.Space.x2) {
                    Button("Discard", role: .destructive) {
                        Task { await model.discardInterrupted() }
                    }
                    .buttonStyle(.field)
                    Spacer()
                    Button("Save it") { Task { await model.saveInterrupted() } }
                        .buttonStyle(.field)
                    Button("Keep recording") { Task { await model.continueInterrupted() } }
                        .buttonStyle(.fieldProminent)
                }
            }
            .padding(Field.Space.x4)
            .fieldSurface()
            .padding(.horizontal, Field.Space.x6)
        }
        .transition(.opacity)
    }

    /// The state, in the place a label would otherwise just say DIST.
    private var recordingLabel: String {
        switch model.recorder.state {
        case .recording: "RECORDING"
        case .paused(.manual): "PAUSED"
        // Named differently on purpose: the app did this, not the user, and
        // somebody staring at a frozen distance deserves to know which.
        case .paused(.automatic): "AUTO-PAUSED"
        case .idle, .stopped: "RECORDED"
        }
    }

    /// One button, one job at a time: tap toggles running and paused, hold
    /// saves.
    ///
    /// Floating over the map rather than in the control row, because it is
    /// the only control whose job changes with the state of the app, and a
    /// row of equal-weight icons is the wrong place for the one thing that is
    /// never equal weight.
    ///
    /// The split is what keeps it to one button. A manual pause deliberately
    /// never ends itself, so resume has to exist or the forgotten-pause
    /// recovery can never fire — and here resume is simply tapping again. The
    /// terminal action gets the deliberate gesture, which is also the right
    /// weight for it: ending a hike by brushing a button is the mistake worth
    /// designing against.
    private var recordControl: some View {
        VStack(alignment: .trailing, spacing: Field.Space.x2) {
            // The hold is invisible, as every long press is, so it is spelled
            // out in the one state where somebody is looking for a way to
            // finish. The inspect long-press can stay unlabelled because
            // nothing is lost by never finding it; this one ends the hike.
            if model.isRecording {
                Text("HOLD TO SAVE")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(Field.textDim)
                    .padding(.horizontal, Field.Space.x2)
                    .padding(.vertical, 3)
                    .fieldOverlay(Field.Radius.control)
                    .transition(.opacity)
            }

            Button {
                switch model.recorder.state {
                case .idle, .stopped: Task { await model.startRecording() }
                case .recording: model.pauseRecording()
                case .paused: model.resumeRecording()
                }
            } label: {
                Image(systemName: recordGlyph)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(recordGlyphColor)
                    .frame(width: 60, height: 60)
            }
            .background(recordFill, in: .circle)
            .overlay(Circle().stroke(
                model.isRecording ? Field.accent : Field.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
            // Stopping is what saves: it fills elevations from the DEM and
            // writes the track. Only reachable while there is something to
            // save, so a hold on an idle button does nothing rather than
            // something surprising.
            .onLongPressGesture(minimumDuration: 0.5) {
                guard model.isRecording else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task { await model.stopRecording() }
            }
        }
        .animation(Field.drawer(), value: model.recorder.state)
        .padding(.trailing, Field.Space.x4)
        .padding(.bottom, Field.Space.x4)
    }

    private var recordGlyphColor: Color {
        switch model.recorder.state {
        case .recording: Field.onAccent
        case .paused: Field.accentText
        // Red only when it means "this will start recording". Once running,
        // the accent carries it and a red glyph would read as an alert.
        case .idle, .stopped: Field.danger
        }
    }

    /// Paused reads dimmer than running, so a glance tells them apart even
    /// when the glyph is small.
    private var recordFill: Color {
        switch model.recorder.state {
        case .recording: Field.accent
        case .paused: Field.accentFill
        case .idle, .stopped: Field.bg1
        }
    }

    private var recordGlyph: String {
        switch model.recorder.state {
        case .idle, .stopped: "record.circle"
        case .recording: "pause.fill"
        // Paused shows the way back out of it, which is what a tap does here.
        case .paused: "play.fill"
        }
    }

    // ---------- formatting ----------

    /// Yards under a tenth of a mile, because "0.04 mi" is not a distance
    /// anybody pictures.
    private func distance(_ metres: Double) -> String {
        let miles = metres / Units.metersPerMile
        if miles < 0.1 {
            return "\(Int((metres * 1.09361).rounded())) yd"
        }
        return String(format: "%.2f mi", miles)
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours):\(String(format: "%02d", minutes))" }
        return "\(minutes):\(String(format: "%02d", total % 60))"
    }

    // ---------- stats ----------

    private var statsBar: some View {
        HStack(spacing: Field.Space.x4) {
            stat("DIST", String(format: "%.2f", model.stats.distanceMiles), "mi")
            Divider().frame(height: 26).overlay(Field.line)
            stat("GAIN", String(format: "%.0f", model.stats.gainFeet), "ft")

            if model.isBusy {
                Divider().frame(height: 26).overlay(Field.line)
                ProgressView().controlSize(.small).tint(Field.accent)
            }
        }
        .padding(.horizontal, Field.Space.x4)
        .padding(.vertical, Field.Space.x3)
        .fieldOverlay()
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            FieldLabel(label)
            Readout(value: value, unit: unit, size: 20)
        }
    }

    private var terrainActive: Bool {
        model.terrainOverlay != nil || model.hillshadeEnabled
    }

    // ---------- legend ----------

    private func legend(for overlay: TerrainOverlay) -> some View {
        VStack(alignment: .leading, spacing: Field.Space.x2) {
            HStack(spacing: Field.Space.x1) {
                ForEach(Array(overlay.legend.enumerated()), id: \.offset) { _, entry in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(
                                red: Double(entry.color.red) / 255,
                                green: Double(entry.color.green) / 255,
                                blue: Double(entry.color.blue) / 255))
                            .frame(height: 8)
                        Text(entry.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Field.textDim)
                    }
                }
            }
            Text(overlay.note)
                .font(.system(size: 9))
                .foregroundStyle(Field.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Field.Space.x3)
        .padding(.vertical, Field.Space.x2)
        .fieldOverlay(Field.Radius.card)
    }

    // ---------- controls ----------

    private var controls: some View {
        HStack(spacing: Field.Space.x2) {
            // The map controls stay available while recording — looking at
            // slope or relief mid-hike is the point of having them.
            if !model.isRecording {
                basemapPicker
            }

            Menu {
                Toggle("Hillshade", isOn: Binding(
                    get: { model.hillshadeEnabled },
                    set: { model.hillshadeEnabled = $0 }
                ))
                Divider()
                Button("No overlay") { model.terrainOverlay = nil }
                ForEach(TerrainOverlay.allCases) { overlay in
                    Button(overlay.label) { model.terrainOverlay = overlay }
                }
            } label: {
                Image(systemName: terrainActive ? "mountain.2.fill" : "mountain.2")
                    .frame(width: 20)
            }
            .buttonStyle(.field(active: terrainActive))

            // Route editing is inert while recording, so its controls go
            // rather than sitting there enabled and doing nothing. Terrain
            // and sources stay: reading the ground mid-hike is the point.
            if !model.isRecording {
                Button { showDiscover = true } label: {
                    Image(systemName: "sparkle.magnifyingglass").frame(width: 20)
                }
                .buttonStyle(.field)
            }

            Spacer()

            // Four controls plus the basemap picker is what the width holds.
            // Recordings, undo and clear go here rather than overflowing off
            // the edge; sources stays visible, because provenance is the
            // product and that was a deliberate call.
            if !model.isRecording {
                Menu {
                    Button {
                        showTracks = true
                    } label: {
                        Label("Recordings (\(model.savedTracks.count))",
                              systemImage: "list.bullet")
                    }
                    .disabled(model.savedTracks.isEmpty)

                    Divider()

                    Button { model.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!model.canUndo)

                    // Clearing is undoable, so it does not stop to ask. A
                    // confirm dialog on a reversible action just trains
                    // people to click through the ones that matter.
                    Button(role: .destructive) { model.clear() } label: {
                        Label("Clear route", systemImage: "trash")
                    }
                    .disabled(model.route.isEmpty)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20)
                }
                .buttonStyle(.field)
            }

            // Provenance is the product, not a debug affordance, so it gets
            // a permanent control rather than living in a menu.
            Button { showSources = true } label: {
                Image(systemName: "antenna.radiowaves.left.and.right").frame(width: 20)
            }
            .buttonStyle(.field(active: model.hasStaleSource))
            .disabled(model.provenance.isEmpty)


        }
        .padding(.horizontal, Field.Space.x3)
        .padding(.vertical, Field.Space.x3)
        .background(Field.bg0.opacity(0.92))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Field.line).frame(height: 1)
        }
    }

    /// Hand-rolled rather than a segmented Picker, which cannot show a fill
    /// and a border on the selected segment.
    private var basemapPicker: some View {
        HStack(spacing: 0) {
            ForEach(Basemap.allCases) { basemap in
                let isOn = model.basemap == basemap
                Button {
                    model.basemap = basemap
                } label: {
                    Text(basemap.label)
                        .font(.system(size: Field.Size.xs, weight: isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Field.accentText : Field.textDim)
                        // One line always: "OpenTopo" wrapping to "Open Topo"
                        // makes the control taller than everything beside it.
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Field.Space.x3)
                        .padding(.vertical, 7)
                        .background(isOn ? Field.accentFill : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(.rect(cornerRadius: Field.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Field.Radius.control)
                .stroke(Field.line, lineWidth: 1))
    }
}
