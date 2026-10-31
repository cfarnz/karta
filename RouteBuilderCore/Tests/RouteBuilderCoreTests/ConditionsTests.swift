import Foundation
import Testing
@testable import RouteBuilderCore

@Suite("Air quality banding and trend match the web app")
struct AirQualityTests {

    @Test func `the EPA band boundaries are inclusive at each top`() {
        let expected: [(Int, String)] = [
            (0, "Good"), (50, "Good"),
            (51, "Moderate"), (100, "Moderate"),
            (101, "Unhealthy for sensitive groups"), (150, "Unhealthy for sensitive groups"),
            (151, "Unhealthy"), (200, "Unhealthy"),
            (201, "Very unhealthy"), (300, "Very unhealthy"),
            (301, "Hazardous"), (500, "Hazardous"),
        ]
        for (aqi, label) in expected {
            #expect(AQIBand.of(aqi).label == label)
        }
    }

    // The swatches are the EPA's published colours, which people already read
    // from AirNow, so they are pinned rather than left to the design system.
    @Test func `the band colours are the published EPA swatches`() {
        #expect(AQIBand.of(25).color == RGB(0, 228, 0))
        #expect(AQIBand.of(75).color == RGB(255, 255, 0))
        #expect(AQIBand.of(125).color == RGB(255, 126, 0))
        #expect(AQIBand.of(175).color == RGB(255, 0, 0))
        #expect(AQIBand.of(250).color == RGB(143, 63, 151))
        #expect(AQIBand.of(400).color == RGB(126, 0, 35))
    }

    // Bright yellow needs dark text; deep maroon needs light.
    @Test func `text contrast flips above the moderate band`() {
        #expect(AQIBand.of(50).prefersDarkText)
        #expect(AQIBand.of(100).prefersDarkText)
        #expect(!AQIBand.of(101).prefersDarkText)
        #expect(!AQIBand.of(400).prefersDarkText)
    }

    @Test func `only the Good band withholds advice`() {
        #expect(AQIBand.of(20).advice == nil)
        #expect(AQIBand.of(75).advice != nil)
        #expect(AQIBand.of(400).advice != nil)
    }

    // ---------- trend ----------

    private static let improving = [92, 88, 70, 55, 45, 40, 38, 36, 35, 35, 34, 34]
    private static let worsening = [40, 45, 60, 80, 95, 110, 120, 118, 115, 110, 108, 105]
    private static let flat = [50, 52, 51, 49, 50, 53, 48, 50, 51, 52, 49, 50]

    @Test func `smoke clearing through the morning reads as improving`() {
        let trend = AQIMath.trend(hourly: Self.improving.map { Optional($0) })
        #expect(trend?.direction == .improving)
        #expect(trend?.value == 34)
        #expect(trend?.hours == 10)
    }

    @Test func `smoke building reads as worsening`() {
        let trend = AQIMath.trend(hourly: Self.worsening.map { Optional($0) })
        #expect(trend?.direction == .worsening)
        #expect(trend?.value == 120)
        #expect(trend?.hours == 6)
    }

    // A flat curve is not worth a line in the card.
    @Test func `a curve inside the noise reports nothing`() {
        #expect(AQIMath.trend(hourly: Self.flat.map { Optional($0) }) == nil)
    }

    @Test func `too few hours to judge reports nothing`() {
        #expect(AQIMath.trend(hourly: [50, 90, 30].map { Optional($0) }) == nil)
        #expect(AQIMath.trend(hourly: []) == nil)
    }

    // A cached response must not report a trend that already happened, so the
    // window starts at the hour the current reading came from.
    @Test func `the window starts at the current reading's hour`() {
        let trend = AQIMath.trend(hourly: Self.improving.map { Optional($0) },
                                  startingAt: 2)
        #expect(trend?.direction == .improving)
        #expect(trend?.value == 34)
        #expect(trend?.hours == 8)
    }

    @Test func `an out of range start reports nothing rather than crashing`() {
        #expect(AQIMath.trend(hourly: Self.improving.map { Optional($0) },
                              startingAt: 99) == nil)
        #expect(AQIMath.trend(hourly: Self.improving.map { Optional($0) },
                              startingAt: -1) == nil)
    }

    @Test func `missing hours are skipped, not treated as zero`() {
        var hourly: [Int?] = Self.improving.map { Optional($0) }
        hourly[1] = nil
        hourly[3] = nil
        let trend = AQIMath.trend(hourly: hourly)
        #expect(trend?.direction == .improving)
        #expect(trend?.value == 34)
    }
}

@Suite("Weather decoding")
struct WeatherTests {

    @Test func `WMO codes map to the web app's wording`() {
        #expect(WeatherCode.describe(0) == "Clear")
        #expect(WeatherCode.describe(3) == "Overcast")
        #expect(WeatherCode.describe(75) == "Heavy snow")
        #expect(WeatherCode.describe(99) == "Thunderstorms with hail")
    }

    @Test func `an unknown or missing code is omitted rather than guessed`() {
        #expect(WeatherCode.describe(7) == nil)
        #expect(WeatherCode.describe(nil) == nil)
    }

    @Test func `three day precipitation sums across the forecast`() {
        let sample = WeatherSample(
            temperatureF: 41, windMph: 12, windDirectionDegrees: 270,
            conditions: "Overcast", highF: 48, lowF: 29,
            precipitationIn: [0.12, 0, 0.4])
        #expect(abs(sample.precipitationTotalIn - 0.52) < 1e-9)
    }
}

@Suite("Alerts")
struct AlertTests {

    // The NWS feed is inconsistent about which field is populated.
    @Test func `an alert falls back to its event when there is no headline`() {
        #expect(WeatherAlert(event: "Winter Storm Warning", severity: "Severe",
                             headline: nil).summary == "Winter Storm Warning")
        #expect(WeatherAlert(event: "Winter Storm Warning", severity: "Severe",
                             headline: "Warning until 6 PM").summary
                == "Warning until 6 PM")
        #expect(WeatherAlert(event: nil, severity: nil, headline: nil).summary == nil)
    }
}
