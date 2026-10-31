import Foundation

/// Web Mercator slippy-map tile arithmetic.
///
/// The web app never needed this — MapLibre asked for a tile by name and the
/// protocol handler answered. Supplying one stitched image instead means
/// working out which tiles cover the view and exactly where the result sits
/// on the ground, so the maths has to be explicit.
public enum TileMath {
    public static let tileSize = 256

    public static func tileCount(zoom: Int) -> Double { pow(2, Double(zoom)) }

    // ---------- geographic -> tile ----------

    public static func tileX(longitude: Double, zoom: Int) -> Double {
        (longitude + 180) / 360 * tileCount(zoom: zoom)
    }

    public static func tileY(latitude: Double, zoom: Int) -> Double {
        // Clamped to the Mercator limit; past it the projection diverges.
        let clamped = min(85.05112878, max(-85.05112878, latitude))
        let radians = clamped * .pi / 180
        let y = (1 - log(tan(radians) + 1 / cos(radians)) / .pi) / 2
        return y * tileCount(zoom: zoom)
    }

    // ---------- tile -> geographic ----------

    public static func longitude(tileX: Double, zoom: Int) -> Double {
        tileX / tileCount(zoom: zoom) * 360 - 180
    }

    public static func latitude(tileY: Double, zoom: Int) -> Double {
        let n = Double.pi - 2 * .pi * tileY / tileCount(zoom: zoom)
        return atan(sinh(n)) * 180 / .pi
    }

    // ---------- coverage ----------

    /// The inclusive range of tiles covering a bounding box.
    public struct TileRange: Equatable, Sendable {
        public var zoom: Int
        public var minX: Int
        public var maxX: Int
        public var minY: Int
        public var maxY: Int

        public var columns: Int { maxX - minX + 1 }
        public var rows: Int { maxY - minY + 1 }
        public var count: Int { columns * rows }

        /// Pixel dimensions of the stitched mosaic.
        public var pixelWidth: Int { columns * TileMath.tileSize }
        public var pixelHeight: Int { rows * TileMath.tileSize }

        /// Geographic corners of the mosaic. Because the range snaps to tile
        /// boundaries this rectangle is exact in Mercator, which is what lets
        /// it be handed over as an image quad without resampling.
        public var west: Double { TileMath.longitude(tileX: Double(minX), zoom: zoom) }
        public var east: Double { TileMath.longitude(tileX: Double(maxX + 1), zoom: zoom) }
        public var north: Double { TileMath.latitude(tileY: Double(minY), zoom: zoom) }
        public var south: Double { TileMath.latitude(tileY: Double(maxY + 1), zoom: zoom) }

        public func tiles() -> [(x: Int, y: Int)] {
            var out: [(x: Int, y: Int)] = []
            out.reserveCapacity(count)
            for y in minY...maxY {
                for x in minX...maxX { out.append((x, y)) }
            }
            return out
        }
    }

    /// Tiles covering a bounding box, with the zoom reduced until the mosaic
    /// fits inside `maxTiles`.
    ///
    /// The cap matters: a wide view at the source zoom would be hundreds of
    /// tiles, which is both a download storm and more pixels than a phone
    /// should push through Horn's method at once. Dropping a zoom level
    /// quarters the count.
    public static func cover(
        west: Double,
        south: Double,
        east: Double,
        north: Double,
        preferredZoom: Int,
        maxTiles: Int = 16
    ) -> TileRange {
        var zoom = min(SlopeMath.overlayMaxZoom, max(0, preferredZoom))

        while true {
            let limit = Int(tileCount(zoom: zoom)) - 1
            let minX = max(0, min(limit, Int(floor(tileX(longitude: west, zoom: zoom)))))
            let maxX = max(0, min(limit, Int(floor(tileX(longitude: east, zoom: zoom)))))
            // Tile Y grows southward, so the northern edge gives the minimum.
            let minY = max(0, min(limit, Int(floor(tileY(latitude: north, zoom: zoom)))))
            let maxY = max(0, min(limit, Int(floor(tileY(latitude: south, zoom: zoom)))))

            let range = TileRange(
                zoom: zoom,
                minX: Swift.min(minX, maxX), maxX: Swift.max(minX, maxX),
                minY: Swift.min(minY, maxY), maxY: Swift.max(minY, maxY)
            )
            if range.count <= maxTiles || zoom == 0 { return range }
            zoom -= 1
        }
    }
}
