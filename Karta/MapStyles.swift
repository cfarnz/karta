import Foundation
import RouteBuilderCore

/// Basemaps, as MapLibre style JSON.
///
/// Both are plain raster tile sources with no API key, which is what let the
/// web app stay a static site and is why the iOS app needs no secrets either.
enum Basemap: String, CaseIterable, Identifiable {
    case openTopo
    case usgs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openTopo: "OpenTopo"
        case .usgs: "USGS"
        }
    }

    var tiles: [String] {
        switch self {
        case .openTopo:
            ["a", "b", "c"].map { "https://\($0).tile.opentopomap.org/{z}/{x}/{y}.png" }
        case .usgs:
            ["https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}"]
        }
    }

    var attribution: String {
        switch self {
        case .openTopo: "© OpenTopoMap (CC-BY-SA) © OpenStreetMap contributors"
        case .usgs: "USGS The National Map"
        }
    }

    var maxZoom: Int {
        switch self {
        case .openTopo: 17
        case .usgs: 16
        }
    }
}

enum MapStyle {
    /// Terrarium DEM from AWS Open Data — no key, and the same tiles the slope
    /// and aspect overlays decode by hand, so 3D relief needs no second source.
    static let terrariumTiles = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
    /// Terrarium publishes to z15. Past the source zoom the extra detail is
    /// interpolation, so let the renderer overzoom rather than invent terrain.
    static let demMaxZoom = 14
    /// Hillshade strength. The stock 0.5 is tuned for a plain basemap; over
    /// a topo sheet that already carries relief shading it doubles up and
    /// muddies the contour lines, so this sits lower.
    static let hillshadeExaggeration = 0.35
    /// Light from the north-west, the cartographic convention. Anchored to
    /// the map rather than the viewport so the shading stays fixed to the
    /// ground when the map rotates.
    static let hillshadeIlluminationDirection = 335.0

    static func json(for basemap: Basemap, includeDEM: Bool) -> String {
        var sources: [String: Any] = [
            "base": [
                "type": "raster",
                "tileSize": 256,
                "tiles": basemap.tiles,
                "attribution": basemap.attribution,
                "maxzoom": basemap.maxZoom,
            ]
        ]

        if includeDEM {
            sources["dem"] = [
                "type": "raster-dem",
                "tiles": [terrariumTiles],
                "encoding": "terrarium",
                "tileSize": 256,
                "maxzoom": demMaxZoom,
                "attribution": "Terrain from AWS Terrain Tiles",
            ]
        }

        let style: [String: Any] = [
            "version": 8,
            "sources": sources,
            "layers": [["id": "base", "type": "raster", "source": "base"]],
        ]

        let data = try? JSONSerialization.data(withJSONObject: style)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// MapLibre Native takes a style URL rather than inline JSON, so the style
    /// is written to a temp file and handed over as a file URL.
    static func url(for basemap: Basemap, includeDEM: Bool) -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("karta-styles", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = "\(basemap.rawValue)-\(includeDEM ? "dem" : "flat").json"
        let url = directory.appendingPathComponent(name)
        try? Data(json(for: basemap, includeDEM: includeDEM).utf8)
            .write(to: url, options: .atomic)
        return url
    }
}


/// What a loaded style was built from, so the map only reloads when the
/// inputs actually change.
struct StyleDescriptor: Equatable {
    var basemap: Basemap
    var hillshade: Bool
}
