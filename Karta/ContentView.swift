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
                    fit: model.pendingFit,
                    centerProvider: $mapCenter)
                .ignoresSafeArea()

            VStack(spacing: Field.Space.x2) {
                statsBar
                if let overlay = model.terrainOverlay {
                    legend(for: overlay)
                }
            }
            .padding(.horizontal, Field.Space.x3)
        }
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
            basemapPicker

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

            Button { showDiscover = true } label: {
                Image(systemName: "sparkle.magnifyingglass").frame(width: 20)
            }
            .buttonStyle(.field)

            Spacer()

            // Provenance is the product, not a debug affordance, so it gets
            // a permanent control rather than living in a menu.
            Button { showSources = true } label: {
                Image(systemName: "antenna.radiowaves.left.and.right").frame(width: 20)
            }
            .buttonStyle(.field(active: model.hasStaleSource))
            .disabled(model.provenance.isEmpty)

            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 20)
            }
            .buttonStyle(.field)
            .disabled(!model.canUndo)

            // Clearing is undoable, so it does not stop to ask. A confirm
            // dialog on a reversible action just trains people to click
            // through the ones that matter.
            Button { model.clear() } label: {
                Image(systemName: "trash").frame(width: 20)
            }
            .buttonStyle(.field)
            .disabled(model.route.isEmpty)
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
