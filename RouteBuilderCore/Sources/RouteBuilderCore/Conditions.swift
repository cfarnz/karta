import Foundation

/// Weather, air quality and active alerts. All keyless, all cached.

// ---------- weather ----------

public struct WeatherSample: Sendable, Equatable {
    public var temperatureF: Double?
    public var windMph: Double?
    public var windDirectionDegrees: Double?
    public var conditions: String?
    public var highF: Double?
    public var lowF: Double?
    /// Daily totals for the next three days, in inches.
    public var precipitationIn: [Double]

    public var precipitationTotalIn: Double { precipitationIn.reduce(0, +) }
}

public enum WeatherCode {
    /// WMO codes, trimmed to the ones Open-Meteo actually returns.
    static let descriptions: [Int: String] = [
        0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast",
        45: "Fog", 48: "Rime fog", 51: "Light drizzle", 53: "Drizzle",
        55: "Heavy drizzle", 61: "Light rain", 63: "Rain", 65: "Heavy rain",
        71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
        80: "Rain showers", 81: "Rain showers", 82: "Violent rain showers",
        85: "Snow showers", 86: "Heavy snow showers", 95: "Thunderstorms",
        96: "Thunderstorms with hail", 99: "Thunderstorms with hail",
    ]

    public static func describe(_ code: Int?) -> String? {
        code.flatMap { descriptions[$0] }
    }
}

// ---------- air quality ----------

/// EPA AQI category.
///
/// The colours are the published EPA swatches rather than the app's palette.
/// People already read these from AirNow and PurpleAir, so this is one of the
/// few places worth leaving the design system alone.
public struct AQIBand: Sendable, Equatable {
    public var upperBound: Int
    public var label: String
    public var color: RGB
    public var advice: String?

    public static let all: [AQIBand] = [
        .init(upperBound: 50, label: "Good",
              color: RGB(0, 228, 0), advice: nil),
        .init(upperBound: 100, label: "Moderate",
              color: RGB(255, 255, 0),
              advice: "Fine for most. Unusually sensitive people may want an easier effort."),
        .init(upperBound: 150, label: "Unhealthy for sensitive groups",
              color: RGB(255, 126, 0),
              advice: "Hard efforts will feel it. Asthma and heart conditions should back off."),
        .init(upperBound: 200, label: "Unhealthy",
              color: RGB(255, 0, 0),
              advice: "Everyone feels this on a climb. Shorten it or move it."),
        .init(upperBound: 300, label: "Very unhealthy",
              color: RGB(143, 63, 151), advice: "Not a day to train outside."),
        .init(upperBound: .max, label: "Hazardous",
              color: RGB(126, 0, 35), advice: "Stay inside."),
    ]

    public static func of(_ aqi: Int) -> AQIBand {
        all.first { aqi <= $0.upperBound } ?? all[all.count - 1]
    }

    /// EPA swatches run from bright yellow to deep maroon, so the text colour
    /// is picked off the band rather than assuming a dark pill.
    public var prefersDarkText: Bool { upperBound <= 100 }
}

public struct AQITrend: Sendable, Equatable {
    public enum Direction: String, Sendable { case improving, worsening }
    public var direction: Direction
    public var value: Int
    /// Hours from now until that reading.
    public var hours: Int
}

public struct AirQualitySample: Sendable, Equatable {
    public var aqi: Int
    public var pm25: Double?
    public var trend: AQITrend?

    public var band: AQIBand { AQIBand.of(aqi) }
}

public enum AQIMath {
    /// A change worth mentioning. Smaller swings are inside the noise of a
    /// model that is itself interpolating.
    public static let meaningfulChange = 20
    public static let lookaheadHours = 12

    /// Look ahead for a meaningfully different reading.
    ///
    /// Wildfire smoke is the mountain-west air quality story and it runs on a
    /// daily cycle — smoke settles into valleys overnight and lifts through
    /// the morning. "92 now, down to 45 by noon" is the useful fact; a flat
    /// curve is not worth a line in the card.
    public static func trend(hourly: [Int?], startingAt index: Int = 0) -> AQITrend? {
        guard index >= 0, index < hourly.count else { return nil }
        let window = hourly[index..<min(index + lookaheadHours, hourly.count)].compactMap { $0 }
        guard window.count >= 4, let now = window.first,
              let best = window.min(), let worst = window.max()
        else { return nil }

        if worst - now >= meaningfulChange {
            return AQITrend(direction: .worsening, value: worst,
                            hours: window.firstIndex(of: worst) ?? 0)
        }
        if now - best >= meaningfulChange {
            return AQITrend(direction: .improving, value: best,
                            hours: window.firstIndex(of: best) ?? 0)
        }
        return nil
    }
}

// ---------- alerts ----------

public struct WeatherAlert: Sendable, Equatable {
    public var event: String?
    public var severity: String?
    public var headline: String?

    /// What the card shows. The feed is inconsistent about which of these is
    /// populated, so fall back rather than render an empty line.
    public var summary: String? { headline ?? event }
}

// ---------- wire formats ----------

struct OpenMeteoForecast: Codable {
    struct Current: Codable {
        var temperature_2m: Double?
        var wind_speed_10m: Double?
        var wind_direction_10m: Double?
        var weather_code: Int?
    }
    struct Daily: Codable {
        var temperature_2m_max: [Double?]?
        var temperature_2m_min: [Double?]?
        var precipitation_sum: [Double?]?
    }
    var current: Current?
    var daily: Daily?
}

struct OpenMeteoAirQuality: Codable {
    struct Current: Codable {
        var time: String?
        var us_aqi: Double?
        var pm2_5: Double?
    }
    struct Hourly: Codable {
        var time: [String]?
        var us_aqi: [Double?]?
    }
    var current: Current?
    var hourly: Hourly?
}

struct NWSAlerts: Codable {
    struct Feature: Codable {
        struct Properties: Codable {
            var event: String?
            var severity: String?
            var headline: String?
        }
        var properties: Properties?
    }
    var features: [Feature]?
}
