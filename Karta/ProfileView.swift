import SwiftUI
import Charts
import RouteBuilderCore

/// Distance-versus-elevation chart with a drag-to-scrub readout.
///
/// All the arithmetic — cumulative distance, the axis domains, the nearest
/// point to a scrub — lives in `ElevationProfile` and is tested against the
/// web app's numbers. This file only draws.
struct ProfileView: View {
    let profile: ElevationProfile
    /// Shared with the map, which marks the same spot on the ground. Nil when
    /// the finger lifts.
    @Binding var cursor: ProfilePoint?

    private static let accent = Color(red: 0.98, green: 0.45, blue: 0.18)
    private static let height: CGFloat = 108

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            chart
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // ---------- header ----------

    /// Shows the scrub readout while dragging and the route's low/high
    /// otherwise, so the row never collapses and the chart never shifts.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("ELEVATION")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            if let cursor {
                readout(String(format: "%.2f", cursor.distanceMiles), "mi")
                Text("·").foregroundStyle(.tertiary)
                readout(Self.feet(cursor.elevationFeet), "ft")
                    .foregroundStyle(Self.accent)
            } else {
                readout(Self.feet(profile.lowestFeet), "lo")
                Text("·").foregroundStyle(.tertiary)
                readout(Self.feet(profile.highestFeet), "hi")
            }
        }
        .font(.system(size: 11))
    }

    private func readout(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            // Tabular, so the numbers hold still under a moving finger
            // instead of jittering the whole row.
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private static func feet(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }

    // ---------- chart ----------

    private var chart: some View {
        Chart {
            ForEach(Array(profile.points.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("Distance", point.distanceMiles),
                    y: .value("Elevation", point.elevationFeet)
                )
                .foregroundStyle(.linearGradient(
                    colors: [Self.accent.opacity(0.28), Self.accent.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Distance", point.distanceMiles),
                    y: .value("Elevation", point.elevationFeet)
                )
                .foregroundStyle(Self.accent)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.linear)
            }

            if let cursor {
                RuleMark(x: .value("Distance", cursor.distanceMiles))
                    .foregroundStyle(.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))

                PointMark(
                    x: .value("Distance", cursor.distanceMiles),
                    y: .value("Elevation", cursor.elevationFeet)
                )
                .symbolSize(44)
                .foregroundStyle(Self.accent)
            }
        }
        // Fixed to the profile's own domains. Letting Swift Charts infer them
        // would re-nice the axes mid-drag and make the line twitch.
        .chartXScale(domain: profile.distanceRange)
        .chartYScale(domain: profile.elevationRange)
        .chartYAxis {
            AxisMarks(preset: .extended, position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(.primary.opacity(0.07))
                AxisValueLabel(format: FloatingPointFormatStyle<Double>
                    .number.precision(.fractionLength(0)))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(.primary.opacity(0.07))
                AxisValueLabel(format: FloatingPointFormatStyle<Double>
                    .number.precision(.fractionLength(1)))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: Self.height)
        // The domain is the data's true range, so without this the peak rides
        // the top edge and the low point rides the bottom. profile.js got the
        // same effect from an 8px pad inside its viewBox.
        .chartPlotStyle { $0.padding(.vertical, 5) }
        .chartOverlay { proxy in
            // A clear hit target over the plot area only. Asking the proxy to
            // convert the touch gives the real axis position, including the
            // plot's insets — profile.js used a fraction of the full SVG
            // width, so its cursor sat slightly off near either edge.
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        // minimumDistance 0 so a tap reads out too, rather
                        // than needing a deliberate drag.
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                scrub(to: value.location, proxy: proxy, geometry: geometry)
                            }
                            .onEnded { _ in clearScrub() }
                    )
            }
        }
        // A scrub marker left behind after the route changes would point at a
        // spot that is no longer on it.
        .onChange(of: profile) { _, _ in clearScrub() }
    }

    private func scrub(to location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotX = location.x - geometry[proxy.plotAreaFrame].origin.x
        guard let miles = proxy.value(atX: plotX, as: Double.self),
              let point = profile.point(nearestTo: miles)
        else { return }

        if point != cursor { cursor = point }
    }

    private func clearScrub() {
        cursor = nil
    }
}
