import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import RouteBuilderCore

/// Fetches and decodes Terrarium DEM tiles from AWS Open Data.
///
/// Terrain never changes, so a decoded tile is good forever — the only reason
/// to bound the cache is memory. 64 tiles at 256×256 floats is about 16 MB,
/// which covers several screens' worth of panning.
actor TerrariumTileLoader {
    private let http: HTTPFetching
    private var cache: [TileKey: [Float]] = [:]
    private var order: [TileKey] = []
    private let maxTiles: Int

    struct TileKey: Hashable {
        var zoom: Int
        var x: Int
        var y: Int
    }

    init(http: HTTPFetching = URLSessionFetcher(), maxTiles: Int = 64) {
        self.http = http
        self.maxTiles = maxTiles
    }

    private func url(for key: TileKey) -> URL? {
        URL(string: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/"
            + "\(key.zoom)/\(key.x)/\(key.y).png")
    }

    /// Elevations in metres for one tile, row-major, 256×256.
    /// Returns nil when the tile is missing or will not decode — the caller
    /// fills the gap rather than abandoning the whole mosaic.
    func elevations(zoom: Int, x: Int, y: Int) async -> [Float]? {
        let key = TileKey(zoom: zoom, x: x, y: y)
        if let hit = cache[key] { return hit }

        guard let url = url(for: key),
              let data = try? await http.data(from: url),
              let rgba = Self.decodeRGBA(data)
        else { return nil }

        let values = Terrarium.decode(
            rgba: rgba.bytes, width: rgba.width, height: rgba.height)
        guard !values.isEmpty else { return nil }

        cache[key] = values
        order.append(key)
        if order.count > maxTiles {
            let excess = order.count - maxTiles
            for stale in order.prefix(excess) { cache.removeValue(forKey: stale) }
            order.removeFirst(excess)
        }
        return values
    }

    /// Decode a PNG into tightly packed RGBA bytes.
    nonisolated static func decodeRGBA(_ data: Data) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                // Terrarium packs numbers, not colour. Premultiplying or
                // colour-managing the bytes would corrupt the elevations, so
                // the alpha is ignored and the data taken verbatim.
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (bytes, width, height) : nil
    }
}

extension TerrariumTileLoader {
    /// Fetch every tile in a range and stitch them into one elevation grid.
    ///
    /// Stitching before computing slope is not just convenient: the web app
    /// ran Horn's method per tile and clamped at the edges, which left a
    /// one-pixel seam on every tile boundary. A single grid has no interior
    /// edges, so the seams disappear.
    func mosaic(for range: TileMath.TileRange) async -> ElevationGrid? {
        let tiles = range.tiles()
        guard !tiles.isEmpty else { return nil }

        var decoded: [TileKey: [Float]] = [:]
        await withTaskGroup(of: (TileKey, [Float]?).self) { group in
            for tile in tiles {
                let key = TileKey(zoom: range.zoom, x: tile.x, y: tile.y)
                group.addTask { [self] in
                    (key, await elevations(zoom: key.zoom, x: key.x, y: key.y))
                }
            }
            for await (key, values) in group {
                if let values { decoded[key] = values }
            }
        }
        guard !decoded.isEmpty else { return nil }

        let size = TileMath.tileSize
        let width = range.pixelWidth
        let height = range.pixelHeight
        var grid = [Float](repeating: 0, count: width * height)

        for tile in tiles {
            let key = TileKey(zoom: range.zoom, x: tile.x, y: tile.y)
            guard let values = decoded[key], values.count == size * size else { continue }

            let originX = (tile.x - range.minX) * size
            let originY = (tile.y - range.minY) * size
            for row in 0..<size {
                let source = row * size
                let destination = (originY + row) * width + originX
                grid.replaceSubrange(
                    destination..<(destination + size),
                    with: values[source..<(source + size)])
            }
        }

        return ElevationGrid(width: width, height: height, values: grid)
    }
}
