import SwiftUI
import RouteBuilderCore

/// Everything known about one point, in one card.
///
/// Sections appear only when their provider answered. A card with elevation
/// and no avalanche bulletin still beats no card, and on a ridge with one bar
/// that is the normal case — so partial is the designed state, not an error.
struct LocationCardView: View {
    let point: Coordinate
    let summary: LocationSummary?
    let isLoading: Bool

    private static let warn = Color(red: 0.85, green: 0.52, blue: 0.13)
    private static let danger = Color(red: 0.80, green: 0.27, blue: 0.24)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let summary {
                    if let terrain = summary.terrain { terrainSection(terrain) }
                    if let weather = summary.weather { weatherSection(weather) }
                    if let air = summary.air { airSection(air) }
                    if let avalanche = summary.avalanche { avalancheSection(avalanche) }
                    if !summary.alerts.isEmpty { alertsSection(summary.alerts) }

                    if summary.isEmpty {
                        Text("No source could be reached. Check your connection and try again.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the ground…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                disclaimer
            }
            .padding(16)
        }
    }

    // ---------- header ----------

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary?.terrain.map { "\(Self.feet($0.elevationFt)) ft" }
                 ?? (isLoading ? "—" : "Elevation unavailable"))
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .monospacedDigit()
            Text("\(Self.fixed(point.latitude, 4)), \(Self.fixed(point.longitude, 4))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // ---------- terrain ----------

    private func terrainSection(_ terrain: TerrainSample) -> some View {
        let band = SlopeBand.of(terrain.slopeDegrees)

        return section("Terrain") {
            row("Slope", "\(Self.whole(terrain.slopeDegrees))°",
                tint: band == .avalanche ? Self.warn : (band == .steep ? Self.danger : nil))
            row("Aspect", terrain.aspectDegrees.map {
                "\(TerrainMath.compass($0)) (\(Self.whole($0))°)"
            } ?? "flat")

            if let note = band.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Where the number came from, because a slope angle read off a
            // 90 m DEM and one off 1 m lidar are different claims.
            Text("Derived from \(terrain.demProvider) at "
                 + "\(Self.whole(terrain.demResolutionM)) m, sampled "
                 + "\(Self.whole(terrain.spacingM)) m apart. Treat as approximate.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ---------- weather ----------

    private func weatherSection(_ weather: WeatherSample) -> some View {
        section("Weather") {
            if let temperature = weather.temperatureF {
                row("Now", "\(Self.whole(temperature))°F"
                    + (weather.conditions.map { ", \($0)" } ?? ""))
            }
            if let wind = weather.windMph {
                row("Wind", "\(Self.whole(wind)) mph"
                    + (weather.windDirectionDegrees.map {
                        " from \(TerrainMath.compass($0))" } ?? ""))
            }
            if let high = weather.highF, let low = weather.lowF {
                row("Today", "\(Self.whole(high))° / \(Self.whole(low))°")
            }
            if weather.precipitationTotalIn > 0 {
                row("Precip, 3 day",
                    String(format: "%.2f\"", weather.precipitationTotalIn))
            }
        }
    }

    // ---------- air quality ----------

    private func airSection(_ air: AirQualitySample) -> some View {
        let band = air.band

        return section("Air quality") {
            HStack {
                Text("AQI")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(air.aqi) — \(band.label)")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Self.color(band.color), in: .capsule)
                    .foregroundStyle(band.prefersDarkText ? .black : .white)
                    .multilineTextAlignment(.trailing)
            }

            if let pm25 = air.pm25 {
                row("PM2.5", String(format: "%.1f µg/m³", pm25))
            }

            if let trend = air.trend {
                let when = trend.hours <= 1
                    ? "within the hour" : "in about \(trend.hours) hours"
                row("Trend",
                    "\(trend.direction.rawValue), "
                    + "\(trend.direction == .improving ? "down" : "up") to "
                    + "\(trend.value) \(when)",
                    tint: trend.direction == .worsening ? Self.warn : nil)
            }

            if let advice = band.advice {
                Text(advice)
                    .font(.system(size: 11))
                    .foregroundStyle(air.aqi > 100 ? Self.warn : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ---------- avalanche ----------

    private func avalancheSection(_ avalanche: AvalancheZone) -> some View {
        section("Avalanche") {
            if let zone = avalanche.zone { row("Zone", zone) }

            if avalanche.isOffSeason {
                Text("No rating issued. CAIC forecasts run roughly November through May.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let level = avalanche.level, let danger = avalanche.danger {
                    HStack {
                        Text("Danger")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(level) — \(danger)")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Self.hex(avalanche.color) ?? Self.danger, in: .capsule)
                            .foregroundStyle(.black)
                    }
                }
                if let warning = avalanche.warningTitle {
                    Text(warning)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Self.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let advice = avalanche.travelAdvice {
                    Text(advice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // ---------- alerts ----------

    private func alertsSection(_ alerts: [WeatherAlert]) -> some View {
        section("Active alerts (\(alerts.count))") {
            ForEach(Array(alerts.prefix(3).enumerated()), id: \.offset) { _, alert in
                if let summary = alert.summary {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Self.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // ---------- disclaimer ----------

    /// Always last, always present. A slope angle and a danger rating shown
    /// together read as a recommendation unless something says otherwise.
    private var disclaimer: some View {
        // One string literal, not a concatenation: Text only parses markdown
        // from a literal, so `"a" + "b"` would render the asterisks.
        Text("**Not an avalanche forecast.** This is reference data from automated sources. Read the full CAIC bulletin and make your own field observations before committing to terrain.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    // ---------- building blocks ----------

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
        }
    }

    // ---------- formatting ----------

    private static func feet(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    private static func whole(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private static func fixed(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    private static func color(_ rgb: RGB) -> Color {
        Color(red: Double(rgb.red) / 255,
              green: Double(rgb.green) / 255,
              blue: Double(rgb.blue) / 255)
    }

    /// CAIC supplies its own danger colour as a hex string.
    private static func hex(_ string: String?) -> Color? {
        guard var value = string else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let packed = Int(value, radix: 16) else { return nil }
        return Color(red: Double((packed >> 16) & 0xFF) / 255,
                     green: Double((packed >> 8) & 0xFF) / 255,
                     blue: Double(packed & 0xFF) / 255)
    }
}
