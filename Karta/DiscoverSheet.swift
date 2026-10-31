import SwiftUI
import RouteBuilderCore

/// Discover's controls and results.
///
/// The web app's panel used hover to preview a candidate and a click to load
/// it. A touch screen has no hover, so the two steps become select (tap a
/// row, the map draws it behind the sheet) and commit (tap Load). The sheet
/// deliberately sits at a medium detent with background interaction on, so
/// the preview it is driving is actually visible.
struct DiscoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Supplied by the map, used when there is no location fix.
    let mapCenter: () -> Coordinate

    private static let accent = Color(red: 0.98, green: 0.45, blue: 0.18)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sliders
                    findButton
                    status
                    results
                }
                .padding(16)
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // ---------- controls ----------

    @ViewBuilder
    private var sliders: some View {
        @Bindable var model = model

        slider("LOOP DISTANCE",
               value: $model.discoverSettings.targetMiles,
               in: DiscoverSettings.targetRange,
               step: DiscoverSettings.targetStep,
               readout: "\(Int(model.discoverSettings.targetMiles)) mi")

        slider("MAX DIFFICULTY",
               value: $model.discoverSettings.maxEffort,
               in: DiscoverSettings.effortRange,
               step: DiscoverSettings.effortStep,
               readout: model.discoverSettings.effortLabel)

        // Two handles rather than one range control: either can be dragged
        // past the other, and DiscoverSettings sorts them out.
        VStack(alignment: .leading, spacing: 4) {
            label("HIGH POINT", Self.range(model.discoverSettings.highPointRange))
            Slider(value: $model.discoverSettings.highPointMinFt,
                   in: DiscoverSettings.highPointLimits,
                   step: DiscoverSettings.highPointStep)
                .tint(Self.accent)
            Slider(value: $model.discoverSettings.highPointMaxFt,
                   in: DiscoverSettings.highPointLimits,
                   step: DiscoverSettings.highPointStep)
                .tint(Self.accent)
        }

        slider("SEARCH WITHIN",
               value: $model.discoverSettings.radiusMiles,
               in: DiscoverSettings.radiusRange,
               step: DiscoverSettings.radiusStep,
               readout: "\(Int(model.discoverSettings.radiusMiles)) mi of me")

        Toggle(isOn: $model.discoverSettings.mountainsOnly) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Mountains only").font(.system(size: 14))
                Text("Trailheads above \(Int(DiscoverService.mountainTrailheadFt).formatted()) ft")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Self.accent)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        readout: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            label(title, readout)
            Slider(value: value, in: range, step: step).tint(Self.accent)
        }
    }

    private func label(_ title: String, _ readout: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            Text(readout)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
    }

    private static func range(_ feet: ClosedRange<Double>) -> String {
        "\(Int(feet.lowerBound).formatted())–\(Int(feet.upperBound).formatted()) ft"
    }

    // ---------- search ----------

    private var findButton: some View {
        Button {
            Task { await model.runDiscover(mapCenter: mapCenter()) }
        } label: {
            HStack(spacing: 8) {
                if model.isDiscovering {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(model.isDiscovering ? "Searching…" : "Find routes")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Self.accent)
        .disabled(model.isDiscovering)
    }

    @ViewBuilder
    private var status: some View {
        if let message = Self.message(for: model.discoverState) {
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // A determinate bar once the job count is known. Candidate
            // generation routes every loop, so this can run half a minute and
            // a spinner would say nothing about how much is left.
            if case let .searching(done, total) = model.discoverState, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(Self.accent)
            }
        }
    }

    private static func message(for state: AppModel.DiscoverState) -> String? {
        switch state {
        case .idle:
            nil
        case .locating:
            "Locating…"
        case let .searching(done, total):
            total > 0 ? "Generating candidates… \(done)/\(total)" : "Finding trailheads…"
        case let .finished(count, usedMapCenter):
            (usedMapCenter ? "Location unavailable — searched from the map centre. " : "")
            + (count > 0
               ? "\(count) route\(count == 1 ? "" : "s") found — tap to preview, then Load."
               : "No routes matched. Widen the sliders or the search radius and try again.")
        case let .failed(reason):
            "Search failed: \(reason). Try again in a minute."
        case .loading:
            "Loading route into the builder…"
        case let .loaded(name):
            "Loaded \(name) — edit, export, or save."
        }
    }

    // ---------- results ----------

    @ViewBuilder
    private var results: some View {
        if !model.candidates.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.candidates) { candidate in
                    row(candidate)
                }
            }
        }
    }

    private func row(_ candidate: Candidate) -> some View {
        let isSelected = model.previewedCandidate?.id == candidate.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(candidate.name)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                badge(Effort.bucket(candidate.effort))
            }

            Text(Self.meta(candidate))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            if isSelected {
                Button {
                    Task {
                        await model.load(candidate)
                        dismiss()
                    }
                } label: {
                    Text("Load into builder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Self.accent)
                .disabled(model.isDiscovering)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Self.accent.opacity(0.10) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Self.accent.opacity(0.55) : .primary.opacity(0.08),
                        lineWidth: 1)
        )
        .contentShape(.rect)
        .onTapGesture {
            model.previewedCandidate = isSelected ? nil : candidate
        }
    }

    private static func meta(_ candidate: Candidate) -> String {
        let miles = String(format: "%.1f", candidate.distanceMiles)
        let gain = Int(candidate.gainFeet.rounded()).formatted()
        let high = Int(candidate.highPointFt.rounded()).formatted()
        let drive = String(format: "%.0f", candidate.driveMiles)
        return "\(miles) mi · ▲\(gain) ft · high \(high) ft · \(drive) mi away"
    }

    private func badge(_ bucket: Effort.Bucket) -> some View {
        Text(bucket.rawValue.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(0.6)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Self.tint(bucket).opacity(0.18), in: .capsule)
            .foregroundStyle(Self.tint(bucket))
    }

    private static func tint(_ bucket: Effort.Bucket) -> Color {
        switch bucket {
        case .easy: Color(red: 0.26, green: 0.65, blue: 0.40)
        case .moderate: Color(red: 0.22, green: 0.52, blue: 0.76)
        case .hard: Color(red: 0.85, green: 0.52, blue: 0.13)
        case .veryHard: Color(red: 0.80, green: 0.27, blue: 0.24)
        }
    }
}
