import SwiftUI
import RouteBuilderCore

/// Recordings on disk.
///
/// Reads summaries, not tracks: a hike is a few thousand points and a list
/// that decoded every one of them to show a distance would stall on the
/// twentieth hike. The points are only loaded when one is opened or shared.
struct TracksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: ShareableGPX?
    @State private var confirmingDelete: TrackSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recordings")
                    .font(.system(size: Field.Size.lg, weight: .semibold))
                    .foregroundStyle(Field.text)
                Spacer()
                FieldLabel("\(model.savedTracks.count)")
            }
            .padding(.horizontal, Field.Space.x4)
            .padding(.vertical, Field.Space.x3)

            Divider().overlay(Field.line)

            if model.savedTracks.isEmpty {
                Text("No recordings yet.")
                    .font(.system(size: Field.Size.sm))
                    .foregroundStyle(Field.textFaint)
                    .padding(Field.Space.x4)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.savedTracks) { summary in
                            row(summary)
                            Divider().overlay(Field.line)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background(Field.bg1)
        .task { await model.refreshSavedTracks() }
        .sheet(item: $sharing) { item in
            // The system share sheet, which is the one piece of chrome that
            // should look like the system: it is the OS's list of apps, not
            // Karta's.
            ShareSheet(url: item.url)
        }
        // Deleting a recording is the one irreversible thing in the app:
        // there is no undo stack for a hike that only exists here.
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { summary in
            Button("Delete \(summary.name)", role: .destructive) {
                Task { await model.deleteTrack(summary.id) }
            }
        }
    }

    private func row(_ summary: TrackSummary) -> some View {
        HStack(spacing: Field.Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.system(size: Field.Size.sm, weight: .medium))
                    .foregroundStyle(Field.text)
                    .lineLimit(1)

                HStack(spacing: Field.Space.x2) {
                    Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    // Said out loud rather than folded silently into the
                    // distance, same as the live readout.
                    if summary.hasEstimate {
                        Text("· includes an estimate")
                    }
                    if summary.gapCount > 0 {
                        Text("· \(summary.gapCount) gap\(summary.gapCount == 1 ? "" : "s")")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Field.textFaint)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Readout(value: String(format: "%.2f", summary.miles), unit: "mi", size: 15)
                Readout(value: String(format: "%.0f", summary.gainFeet), unit: "ft", size: 12)
            }

            Menu {
                Button("Export GPX") { Task { await share(summary) } }
                Button("Delete", role: .destructive) { confirmingDelete = summary }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Field.textDim)
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, Field.Space.x4)
        .padding(.vertical, Field.Space.x3)
        .contentShape(.rect)
    }

    private func share(_ summary: TrackSummary) async {
        guard let track = await model.loadTrack(summary.id) else { return }
        let gpx = GPX.document(for: track)
        // Written to a real file rather than shared as a string: a string
        // arrives in Mail as pasted text, where a .gpx file arrives as
        // something Gaia and COROS can open.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(GPX.filename(for: track.name))
        guard (try? gpx.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        sharing = ShareableGPX(url: url)
    }
}

private struct ShareableGPX: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
