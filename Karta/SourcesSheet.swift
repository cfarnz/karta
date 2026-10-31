import SwiftUI
import RouteBuilderCore

/// Which source answered, how old the answer is, and whether it is any good.
///
/// Every provider in the app already reports this and nothing used to show
/// it. That was the gap worth closing: a number with no origin is a number
/// you cannot act on, and the difference between "3DEP, live" and "3DEP,
/// stale, 2h ago" is the difference between trusting a slope angle and
/// going to look at it yourself.
struct SourcesSheet: View {
    let records: [ProvenanceRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Field.Space.x2) {
                    if records.isEmpty {
                        Text("Nothing fetched yet. Add a waypoint or inspect a point.")
                            .font(.system(size: Field.Size.sm))
                            .foregroundStyle(Field.textDim)
                            .padding(.top, Field.Space.x2)
                    } else {
                        ForEach(records) { record in
                            row(record)
                        }
                        footnote
                    }
                }
                .padding(Field.Space.x4)
            }
            .background(Field.bg1)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Field.accentText)
                }
            }
        }
    }

    private func row(_ record: ProvenanceRecord) -> some View {
        let state = SourceState(isStale: record.isStale, fromCache: record.fromCache)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.dataset)
                    .font(.system(size: Field.Size.sm, weight: .medium))
                    .foregroundStyle(Field.text)
                Spacer(minLength: Field.Space.x2)
                Text(state.label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(Field.Track.label)
                    .foregroundStyle(state.color)
            }

            Text(record.provider + (record.detail.isEmpty ? "" : " · \(record.detail)"))
                .font(.system(size: Field.Size.xs, design: .monospaced))
                .foregroundStyle(Field.textDim)
                .fixedSize(horizontal: false, vertical: true)

            Text(record.ageDescription)
                .font(.system(size: Field.Size.xs, design: .monospaced))
                .foregroundStyle(Field.textFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Field.Space.x2)
        .padding(.trailing, Field.Space.x3)
        .sourceStripe(state)
        .background(Field.bg2, in: .rect(cornerRadius: Field.Radius.card))
    }

    private var footnote: some View {
        Text("A source that fails serves its last good answer, marked stale, "
             + "rather than an error or a silent zero.")
            .font(.system(size: Field.Size.xs))
            .foregroundStyle(Field.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Field.Space.x2)
    }
}
