import UIKit
import MapLibre
import OSLog
import RouteBuilderCore

/// Draws the slope or aspect overlay as a single georeferenced image.
///
/// MapLibre Native has no equivalent of GL JS's `addProtocol`, so the app
/// cannot answer raster tile requests. `MLNImageSource` is the way in: hand
/// the map one bitmap pinned to a geographic quad, and replace it when the
/// view settles. The quad is snapped to whole Terrarium tiles, which makes it
/// an exact rectangle in Web Mercator and so needs no resampling.
@MainActor
final class SlopeOverlayController {
    static let sourceID = "karta-terrain-overlay"
    static let layerID = "karta-terrain-overlay-layer"

    private let loader = TerrariumTileLoader()
    private let log = Logger(subsystem: "com.cfarnz.karta", category: "overlay")
    private var renderTask: Task<Void, Never>?

    /// What is currently on screen, so an unchanged view does no work.
    private struct Rendered: Equatable {
        var overlay: TerrainOverlay
        var range: TileMath.TileRange
    }
    private var rendered: Rendered?

    /// Cleared when the style is replaced, since the source goes with it.
    func styleWasReplaced() {
        rendered = nil
    }

    func cancel() {
        renderTask?.cancel()
        renderTask = nil
    }

    // ---------- entry point ----------

    func update(mapView: MLNMapView, overlay: TerrainOverlay?) {
        guard let style = mapView.style else { return }

        guard let overlay else {
            remove(from: style)
            rendered = nil
            cancel()
            return
        }

        let bounds = mapView.visibleCoordinateBounds
        let range = TileMath.cover(
            west: bounds.sw.longitude,
            south: bounds.sw.latitude,
            east: bounds.ne.longitude,
            north: bounds.ne.latitude,
            preferredZoom: Int(mapView.zoomLevel.rounded())
        )

        let wanted = Rendered(overlay: overlay, range: range)
        guard rendered != wanted else { return }

        // A pan that lands in the same tile range is free; one that does not
        // supersedes whatever was still rendering.
        cancel()
        renderTask = Task { [weak self, weak mapView] in
            guard let self else { return }
            let image = await self.renderImage(overlay: overlay, range: range)
            guard !Task.isCancelled,
                  let mapView, let style = mapView.style, let image
            else { return }

            self.install(image: image, range: range, on: style)
            self.rendered = wanted
        }
    }

    // ---------- rendering ----------

    private func renderImage(
        overlay: TerrainOverlay,
        range: TileMath.TileRange
    ) async -> UIImage? {
        let startedAt = ContinuousClock.now
        guard let grid = await loader.mosaic(for: range) else { return nil }
        guard !Task.isCancelled else { return nil }
        let tileMillis = (ContinuousClock.now - startedAt).milliseconds

        let zoom = range.zoom
        let originY = Double(range.minY)
        let tileSize = Double(TileMath.tileSize)

        let rgba = OverlayRenderer.render(grid: grid, overlay: overlay) { row in
            // Ground covered by a pixel shrinks toward the poles, so the cell
            // size Horn's method needs is recomputed per row of the mosaic.
            let fractionalTileY = originY + (Double(row) + 0.5) / tileSize
            let latitude = TileMath.latitude(tileY: fractionalTileY, zoom: zoom)
            return SlopeMath.metersPerPixel(latitude: latitude, zoom: zoom)
        }
        guard !rgba.isEmpty, !Task.isCancelled else { return nil }

        let image = Self.image(rgba: rgba, width: grid.width, height: grid.height)
        let totalMillis = (ContinuousClock.now - startedAt).milliseconds
        log.info("overlay \(overlay.rawValue, privacy: .public) z\(range.zoom, privacy: .public) tiles \(range.count, privacy: .public) px \(grid.width, privacy: .public) fetchMs \(tileMillis, privacy: .public) totalMs \(totalMillis, privacy: .public)")
        return image
    }

    nonisolated static func image(rgba: [UInt8], width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }

        // The renderer emits straight (non-premultiplied) alpha, which is the
        // honest form: a band's colour is its colour regardless of opacity.
        // CGBitmapContext has no straight-alpha RGBA mode — only
        // premultipliedLast — and handing it straight bytes makes every pixel
        // composite far too bright, because the colour channel is already
        // larger than the alpha permits. So premultiply here, at the boundary.
        var bytes = rgba
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = UInt16(bytes[index + 3])
            guard alpha != 255 else { continue }
            bytes[index] = UInt8(UInt16(bytes[index]) * alpha / 255)
            bytes[index + 1] = UInt8(UInt16(bytes[index + 1]) * alpha / 255)
            bytes[index + 2] = UInt8(UInt16(bytes[index + 2]) * alpha / 255)
        }

        return bytes.withUnsafeMutableBytes { raw -> UIImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let cgImage = context.makeImage() else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }

    // ---------- style plumbing ----------

    private func install(image: UIImage, range: TileMath.TileRange, on style: MLNStyle) {
        let quad = MLNCoordinateQuadMake(
            CLLocationCoordinate2D(latitude: range.north, longitude: range.west),
            CLLocationCoordinate2D(latitude: range.south, longitude: range.west),
            CLLocationCoordinate2D(latitude: range.south, longitude: range.east),
            CLLocationCoordinate2D(latitude: range.north, longitude: range.east)
        )

        if let existing = style.source(withIdentifier: Self.sourceID) as? MLNImageSource {
            existing.coordinates = quad
            existing.image = image
            return
        }

        let source = MLNImageSource(
            identifier: Self.sourceID, coordinateQuad: quad, image: image)
        style.addSource(source)

        let layer = MLNRasterStyleLayer(identifier: Self.layerID, source: source)
        // Alpha is already baked into the pixels; a second multiply here would
        // wash the bands out.
        layer.rasterOpacity = NSExpression(forConstantValue: 1.0)

        // Terrain reads under the route, never over it.
        if let routeCasing = style.layer(withIdentifier: "karta-route-casing") {
            style.insertLayer(layer, below: routeCasing)
        } else {
            style.addLayer(layer)
        }
    }

    private func remove(from style: MLNStyle) {
        if let layer = style.layer(withIdentifier: Self.layerID) {
            style.removeLayer(layer)
        }
        if let source = style.source(withIdentifier: Self.sourceID) {
            style.removeSource(source)
        }
    }
}


extension Duration {
    /// Whole milliseconds, for log lines.
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
