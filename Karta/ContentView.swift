import SwiftUI
import RouteBuilderCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            MapView(route: model.route,
                    basemap: model.basemap,
                    hillshade: model.hillshadeEnabled,
                    terrainOverlay: model.terrainOverlay)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                statsBar
                if let overlay = model.terrainOverlay {
                    legend(for: overlay)
                }
            }
            .padding(.horizontal, 12)
        }
        .safeAreaInset(edge: .bottom) { controls }
        .task(id: model.route.waypoints.count) {
            // Terrain is re-fetchable, so flushing opportunistically costs
            // nothing and keeps the point cache from living only in memory.
            await model.flushCaches()
        }
    }

    // ---------- stats ----------

    private var statsBar: some View {
        HStack(spacing: 20) {
            stat("DIST", String(format: "%.2f", model.stats.distanceMiles), "mi")
            Divider().frame(height: 26)
            stat("GAIN", String(format: "%.0f", model.stats.gainFeet), "ft")

            if model.isBusy {
                Divider().frame(height: 26)
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var terrainActive: Bool {
        model.terrainOverlay != nil || model.hillshadeEnabled
    }

    // ---------- legend ----------

    private func legend(for overlay: TerrainOverlay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(overlay.note)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                // Tabular so the numbers stop jittering as a drag changes them.
                Text(value)
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // ---------- controls ----------

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Basemap", selection: Binding(
                get: { model.basemap },
                set: { model.basemap = $0 }
            )) {
                ForEach(Basemap.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

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
            }
            .buttonStyle(.bordered)
            .tint(terrainActive ? .orange : nil)

            Spacer()

            Button { model.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)

            Button(role: .destructive) { model.clear() } label: {
                Image(systemName: "trash")
            }
            .disabled(model.route.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}
