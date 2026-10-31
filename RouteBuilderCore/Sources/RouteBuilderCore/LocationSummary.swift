import Foundation

/// Everything known about one point, gathered in one call.
///
/// Modelled on PeakHut's `/v1/locations/summary`: one request fans out to
/// every provider in parallel and returns a single record, each field
/// carrying where it came from. A provider that fails is omitted rather than
/// fatal — a card with elevation and no avalanche bulletin still beats no
/// card, and on a ridge with one bar that is the normal case.
public struct LocationSummary: Sendable, Equatable {
    public var point: Coordinate
    public var terrain: TerrainSample?
    public var weather: WeatherSample?
    public var air: AirQualitySample?
    public var alerts: [WeatherAlert]
    public var avalanche: AvalancheZone?

    /// True when every provider failed, which is worth saying out loud
    /// rather than showing an empty card.
    public var isEmpty: Bool {
        terrain == nil && weather == nil && air == nil
            && alerts.isEmpty && avalanche == nil
    }
}

public actor LocationSummaryService {
    private let http: HTTPFetching
    private let cache: ProviderCache
    private let elevation: ElevationService

    private static let forecast = "https://api.open-meteo.com/v1/forecast"
    private static let airQuality = "https://air-quality-api.open-meteo.com/v1/air-quality"
    private static let nws = "https://api.weather.gov/alerts/active"
    private static let caic = "https://api.avalanche.org/v2/public/products/map-layer/CAIC"

    public init(http: HTTPFetching, cache: ProviderCache, elevation: ElevationService) {
        self.http = http
        self.cache = cache
        self.elevation = elevation
    }

    /// Cache keys round to 2 decimal places, about a kilometre. Two taps on
    /// the same hillside should not be two fetches.
    private static func key(_ prefix: String, _ point: Coordinate) -> String {
        "\(prefix):\(String(format: "%.2f", point.longitude)),"
            + "\(String(format: "%.2f", point.latitude))"
    }

    private static func fixed(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    // ---------- the summary ----------

    public struct Result: Sendable {
        public var summary: LocationSummary
        public var provenance: [ProvenanceRecord]
    }

    public func summary(for point: Coordinate) async -> Result {
        // Each leg returns its own provenance so a partial answer still says
        // which sources it came from.
        async let terrain = self.terrain(at: point)
        async let weather = self.weather(at: point)
        async let air = self.airQuality(at: point)
        async let alerts = self.alerts(at: point)
        async let avalanche = self.avalanche(at: point)

        let (t, w, aq, al, av) = await (terrain, weather, air, alerts, avalanche)

        return Result(
            summary: LocationSummary(
                point: point,
                terrain: t.0, weather: w.0, air: aq.0,
                alerts: al.0 ?? [], avalanche: av.0),
            provenance: [t.1, w.1, aq.1, al.1, av.1].compactMap { $0 }
        )
    }

    // ---------- terrain ----------

    func terrain(at point: Coordinate) async -> (TerrainSample?, ProvenanceRecord?) {
        let provider = ElevationService.provider(for: point)
        let grid = TerrainMath.sampleGrid(around: point, spacingM: provider.spacingM)
        let result = await elevation.preciseElevations(for: grid)

        guard result.values.count == 9,
              let gradients = TerrainMath.gradients(
                elevations: result.values, spacingM: provider.spacingM)
        else { return (nil, result.provenance) }

        let slope = TerrainMath.slopeDegrees(dzdx: gradients.dzdx, dzdy: gradients.dzdy)
        let aspect = slope < TerrainMath.flatBelowDegrees
            ? nil
            : SlopeMath.aspectDegrees(dzdx: gradients.dzdx, dzdy: gradients.dzdy)
                .truncatingRemainder(dividingBy: 360)

        return (
            TerrainSample(
                elevationFt: result.values[4] * Units.feetPerMeter,
                slopeDegrees: slope,
                aspectDegrees: aspect,
                demProvider: result.provenance.provider,
                demResolutionM: result.resolutionM,
                spacingM: provider.spacingM),
            result.provenance
        )
    }

    // ---------- weather ----------

    func weather(at point: Coordinate) async -> (WeatherSample?, ProvenanceRecord?) {
        let url = URL(string: Self.forecast
            + "?latitude=\(Self.fixed(point.latitude, 4))"
            + "&longitude=\(Self.fixed(point.longitude, 4))"
            + "&current=temperature_2m,wind_speed_10m,wind_direction_10m,weather_code"
            + "&daily=temperature_2m_max,temperature_2m_min,precipitation_sum"
            + "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch"
            + "&timezone=auto&forecast_days=3")!

        do {
            let hit = try await cache.cached(key: Self.key("weather", point), ttl: TTL.weather) {
                try JSONDecoder().decode(
                    OpenMeteoForecast.self, from: try await self.http.data(from: url))
            }
            let current = hit.value.current
            let daily = hit.value.daily

            return (
                WeatherSample(
                    temperatureF: current?.temperature_2m,
                    windMph: current?.wind_speed_10m,
                    windDirectionDegrees: current?.wind_direction_10m,
                    conditions: WeatherCode.describe(current?.weather_code),
                    highF: daily?.temperature_2m_max?.first ?? nil,
                    lowF: daily?.temperature_2m_min?.first ?? nil,
                    precipitationIn: (daily?.precipitation_sum ?? []).prefix(3).map { $0 ?? 0 }),
                ProvenanceRecord(dataset: "Weather", provider: "Open-Meteo",
                                 detail: "current + 3 day", at: hit.fetchedAt,
                                 isStale: hit.isStale, fromCache: hit.fromCache)
            )
        } catch {
            return (nil, ProvenanceRecord(dataset: "Weather", provider: "Open-Meteo",
                                          detail: "unreachable", isStale: true))
        }
    }

    // ---------- air quality ----------

    func airQuality(at point: Coordinate) async -> (AirQualitySample?, ProvenanceRecord?) {
        let url = URL(string: Self.airQuality
            + "?latitude=\(Self.fixed(point.latitude, 4))"
            + "&longitude=\(Self.fixed(point.longitude, 4))"
            + "&current=us_aqi,pm2_5&hourly=us_aqi&forecast_days=2&timezone=auto")!

        do {
            let hit = try await cache.cached(key: Self.key("air", point), ttl: TTL.air) {
                try JSONDecoder().decode(
                    OpenMeteoAirQuality.self, from: try await self.http.data(from: url))
            }
            guard let aqi = hit.value.current?.us_aqi else {
                return (nil, ProvenanceRecord(dataset: "Air quality",
                                              provider: "Open-Meteo (CAMS)",
                                              detail: "no reading", at: hit.fetchedAt,
                                              isStale: hit.isStale, fromCache: hit.fromCache))
            }

            // Align the forecast to the hour the current reading came from,
            // so a cached response does not report a trend that already
            // happened.
            let times = hit.value.hourly?.time ?? []
            let index = max(0, hit.value.current?.time.flatMap { times.firstIndex(of: $0) } ?? 0)
            let hourly = (hit.value.hourly?.us_aqi ?? []).map { $0.map { Int($0.rounded()) } }

            return (
                AirQualitySample(
                    aqi: Int(aqi.rounded()),
                    pm25: hit.value.current?.pm2_5,
                    trend: AQIMath.trend(hourly: hourly, startingAt: index)),
                ProvenanceRecord(dataset: "Air quality", provider: "Open-Meteo (CAMS)",
                                 detail: "US AQI + PM2.5", at: hit.fetchedAt,
                                 isStale: hit.isStale, fromCache: hit.fromCache)
            )
        } catch {
            return (nil, ProvenanceRecord(dataset: "Air quality",
                                          provider: "Open-Meteo (CAMS)",
                                          detail: "unreachable", isStale: true))
        }
    }

    // ---------- alerts ----------

    func alerts(at point: Coordinate) async -> ([WeatherAlert]?, ProvenanceRecord?) {
        let url = URL(string: "\(Self.nws)?point="
            + "\(Self.fixed(point.latitude, 4)),\(Self.fixed(point.longitude, 4))")!

        do {
            let hit = try await cache.cached(key: Self.key("alerts", point), ttl: TTL.alerts) {
                let decoded = try JSONDecoder().decode(
                    NWSAlerts.self, from: try await self.http.data(from: url))
                return (decoded.features ?? []).map {
                    StoredAlert(event: $0.properties?.event,
                                severity: $0.properties?.severity,
                                headline: $0.properties?.headline)
                }
            }
            let alerts = hit.value.map {
                WeatherAlert(event: $0.event, severity: $0.severity, headline: $0.headline)
            }
            return (
                alerts,
                ProvenanceRecord(dataset: "Alerts", provider: "NWS",
                                 detail: alerts.isEmpty ? "none active"
                                                        : "\(alerts.count) active",
                                 at: hit.fetchedAt, isStale: hit.isStale,
                                 fromCache: hit.fromCache)
            )
        } catch {
            return (nil, ProvenanceRecord(dataset: "Alerts", provider: "NWS",
                                          detail: "unreachable", isStale: true))
        }
    }

    // ---------- avalanche ----------

    func avalanche(at point: Coordinate) async -> (AvalancheZone?, ProvenanceRecord?) {
        do {
            // One key for the whole state: the response carries every zone,
            // so the lookup is local and works offline once warm.
            let hit = try await cache.cached(key: "avalanche:CAIC", ttl: TTL.avalanche) {
                try JSONDecoder().decode(
                    CAICMapLayer.self,
                    from: try await self.http.data(from: URL(string: Self.caic)!))
            }

            let zone = (hit.value.features ?? []).first {
                guard let geometry = $0.geometry else { return false }
                return GeoPolygon.contains(point, geometry: geometry)
            }

            return (
                zone?.properties?.asZone(),
                ProvenanceRecord(dataset: "Avalanche", provider: "CAIC",
                                 detail: zone?.properties?.name ?? "outside CAIC zones",
                                 at: hit.fetchedAt, isStale: hit.isStale,
                                 fromCache: hit.fromCache)
            )
        } catch {
            return (nil, ProvenanceRecord(dataset: "Avalanche", provider: "CAIC",
                                          detail: "unreachable", isStale: true))
        }
    }
}

/// The cache stores Codable values, and `WeatherAlert` is a view type.
struct StoredAlert: Codable, Sendable {
    var event: String?
    var severity: String?
    var headline: String?
}
