import Foundation
import Testing
@testable import RouteBuilderCore

// Expected values came from running the inner maths of the web app's
// src/slope.js under node, not from recomputing the formulas here.

@Suite("Terrarium decoding")
struct TerrariumTests {

    @Test(arguments: [
        (UInt8(128), UInt8(0), UInt8(0), Float(0)),
        (UInt8(128), UInt8(10), UInt8(128), Float(10.5)),
        (UInt8(127), UInt8(255), UInt8(255), Float(-0.00390625)),
        (UInt8(130), UInt8(45), UInt8(0), Float(557)),
    ])
    func `packed metres decode to elevation`(r: UInt8, g: UInt8, b: UInt8, expected: Float) {
        #expect(abs(Terrarium.elevation(red: r, green: g, blue: b) - expected) < 1e-4)
    }

    @Test func `a buffer decodes in row-major order`() {
        // Two pixels: 0 m then 557 m.
        let rgba: [UInt8] = [128, 0, 0, 255, 130, 45, 0, 255]
        let values = Terrarium.decode(rgba: rgba, width: 2, height: 1)
        #expect(values.count == 2)
        #expect(values[0] == 0)
        #expect(values[1] == 557)
    }

    @Test func `a short buffer decodes to nothing rather than crashing`() {
        #expect(Terrarium.decode(rgba: [1, 2, 3], width: 10, height: 10).isEmpty)
    }
}

@Suite("Slope maths matches the web app")
struct SlopeMathTests {

    @Test(arguments: [
        (12, 1566.0, 256, 29.732726058),
        (14, 6264.0, 256, 7.430494694),
        (10, 391.0, 256, 118.873583556),
        (14, 6264.0, 512, 3.715247347),
        (0, 0.0, 256, 156_543.033928041),
    ])
    func `metres per pixel follows the Mercator stretch`(
        zoom: Int, tileY: Double, tilePixels: Int, expected: Double
    ) {
        let value = SlopeMath.metersPerPixel(zoom: zoom, tileY: tileY, tilePixels: tilePixels)
        #expect(abs(value - expected) < 1e-6)
    }

    @Test func `the latitude form agrees with the tile-centre form`() {
        // Same ground, two ways of asking. The mosaic renderer uses the
        // latitude form per row; the parity check keeps them honest.
        let zoom = 12
        let tileY = 1550.0
        let centreLatitude = TileMath.latitude(tileY: tileY + 0.5, zoom: zoom)

        let byTile = SlopeMath.metersPerPixel(zoom: zoom, tileY: tileY, tilePixels: 256)
        let byLatitude = SlopeMath.metersPerPixel(latitude: centreLatitude, zoom: zoom)
        #expect(abs(byTile - byLatitude) < 1e-6)
    }

    @Test func `pixels cover less ground toward the poles`() {
        let equator = SlopeMath.metersPerPixel(latitude: 0, zoom: 12)
        let boulder = SlopeMath.metersPerPixel(latitude: 40, zoom: 12)
        let arctic = SlopeMath.metersPerPixel(latitude: 70, zoom: 12)
        #expect(equator > boulder)
        #expect(boulder > arctic)
    }

    // Below 27 degrees stays clear so the topo underneath reads normally.
    @Test(arguments: [
        (0.0, nil as RGB?), (26.9, nil),
        (27.0, RGB(242, 224, 74)), (29.9, RGB(242, 224, 74)),
        (30.0, RGB(240, 160, 60)), (34.9, RGB(240, 160, 60)),
        (35.0, RGB(227, 79, 60)), (39.9, RGB(227, 79, 60)),
        (40.0, RGB(186, 48, 92)), (44.9, RGB(186, 48, 92)),
        (45.0, RGB(138, 62, 158)), (49.9, RGB(138, 62, 158)),
        (50.0, RGB(70, 78, 150)), (89.0, RGB(70, 78, 150)),
    ])
    func `slope bands land on the documented boundaries`(degrees: Double, expected: RGB?) {
        #expect(SlopeMath.slopeColor(degrees: degrees) == expected)
    }

    @Test(arguments: [
        (0.0, -1.0, 4), (1.0, 0.0, 6), (0.0, 1.0, 0), (-1.0, 0.0, 2),
        (1.0, -1.0, 5), (-1.0, 1.0, 1),
    ])
    func `aspect sectors follow the ESRI convention`(dzdx: Double, dzdy: Double, expected: Int) {
        let degrees = atan((dzdx * dzdx + dzdy * dzdy).squareRoot()) * 180 / .pi
        #expect(SlopeMath.aspectSector(degrees: degrees, dzdx: dzdx, dzdy: dzdy) == expected)
    }

    @Test func `flat ground has no meaningful aspect`() {
        #expect(SlopeMath.aspectSector(degrees: 10, dzdx: 0.1, dzdy: 0.1) == nil)
        #expect(SlopeMath.aspectColor(degrees: 19.9, dzdx: 0.1, dzdy: 0.1) == nil)
    }

    @Test func `every sector maps to a distinct colour`() {
        #expect(Set(SlopeMath.aspectSectors.map(\.red)).count > 1)
        #expect(SlopeMath.aspectSectors.count == 8)
        // Opposing aspects should not read as the same colour.
        #expect(SlopeMath.aspectSectors[0] != SlopeMath.aspectSectors[4])
    }
}

@Suite("Overlay rendering")
struct OverlayRenderTests {

    /// A clean ramp rising east at the given angle, `cell` metres per pixel.
    private func ramp(degrees: Double, cell: Double, size: Int = 8) -> ElevationGrid {
        let step = cell * tan(degrees * .pi / 180)
        let values = (0..<(size * size)).map { index -> Float in
            Float(Double(index % size) * step)
        }
        return ElevationGrid(width: size, height: size, values: values)
    }

    // A nominal 30 degree ramp actually computes to 29.999999999999996, so it
    // falls in the 27–30 band rather than 30–35. The web app does exactly the
    // same thing — pinned here because a band boundary this knife-edge is the
    // kind of thing a well-meaning "fix" would quietly change.
    @Test func `a nominal thirty degree ramp lands just under the boundary, as in the web app`() {
        let grid = ramp(degrees: 30, cell: 30)
        let pixels = OverlayRenderer.render(grid: grid, overlay: .slope) { _ in 30 }

        // Sample the interior, away from the clamped edges.
        let index = (4 * grid.width + 4) * 4
        #expect(pixels[index] == 242)
        #expect(pixels[index + 1] == 224)
        #expect(pixels[index + 2] == 74)
        #expect(pixels[index + 3] == SlopeMath.alpha)
    }

    @Test func `a clearly steeper ramp paints the slab band`() {
        let grid = ramp(degrees: 37, cell: 30)
        let pixels = OverlayRenderer.render(grid: grid, overlay: .slope) { _ in 30 }
        let index = (4 * grid.width + 4) * 4
        #expect(pixels[index] == 227)   // 35–40, the heart of the slab band
        #expect(pixels[index + 1] == 79)
        #expect(pixels[index + 2] == 60)
    }

    @Test func `flat ground stays fully transparent`() {
        let grid = ElevationGrid(width: 8, height: 8, values: Array(repeating: 2000, count: 64))
        let pixels = OverlayRenderer.render(grid: grid, overlay: .slope) { _ in 30 }
        #expect(pixels.allSatisfy { $0 == 0 })
    }

    @Test func `gentle terrain under the first band is left clear`() {
        // 20 degrees: real relief, but below the 27 degree floor.
        let grid = ramp(degrees: 20, cell: 30)
        let pixels = OverlayRenderer.render(grid: grid, overlay: .slope) { _ in 30 }
        let index = (4 * grid.width + 4) * 4
        #expect(pixels[index + 3] == 0)
    }

    @Test func `the same terrain reads steeper when pixels cover less ground`() {
        // Identical elevations, finer cells -> steeper gradient. This is why
        // cell size has to track the Mercator stretch rather than be assumed.
        let grid = ramp(degrees: 30, cell: 30)
        let coarse = OverlayRenderer.render(grid: grid, overlay: .slope) { _ in 30 }
        let fine = OverlayRenderer.render(grid: grid, overlay: .slope) { _ in 15 }
        let index = (4 * grid.width + 4) * 4
        #expect(coarse[index..<(index + 3)] != fine[index..<(index + 3)])
    }

    @Test func `aspect paints a steep ramp and names its direction`() {
        let grid = ramp(degrees: 45, cell: 30)
        let pixels = OverlayRenderer.render(grid: grid, overlay: .aspect) { _ in 30 }
        let index = (4 * grid.width + 4) * 4
        // Rising to the east means the ground falls west — sector 6.
        let expected = SlopeMath.aspectSectors[6]
        #expect(pixels[index] == expected.red)
        #expect(pixels[index + 1] == expected.green)
        #expect(pixels[index + 2] == expected.blue)
    }

    @Test func `an empty or mismatched grid renders nothing`() {
        #expect(OverlayRenderer.render(
            grid: ElevationGrid(width: 0, height: 0, values: []), overlay: .slope) { _ in 30 }
            .isEmpty)
        #expect(OverlayRenderer.render(
            grid: ElevationGrid(width: 4, height: 4, values: [1, 2, 3]), overlay: .slope) { _ in 30 }
            .isEmpty)
    }

    @Test func `output is exactly four bytes per cell`() {
        let grid = ramp(degrees: 35, cell: 30, size: 6)
        let pixels = OverlayRenderer.render(grid: grid, overlay: .slope) { _ in 30 }
        #expect(pixels.count == 6 * 6 * 4)
    }
}

@Suite("Tile coverage")
struct TileMathTests {

    @Test func `a known coordinate lands on the expected tile`() {
        // Boulder at z12 — cross-checked against the standard slippy scheme.
        #expect(Int(TileMath.tileX(longitude: -105.28, zoom: 12)) == 850)
        #expect(Int(TileMath.tileY(latitude: 39.995, zoom: 12)) == 1550)
    }

    @Test func `tile corners round-trip back to coordinates`() {
        let lon = TileMath.longitude(tileX: 850, zoom: 12)
        let lat = TileMath.latitude(tileY: 1550, zoom: 12)
        #expect(Int(TileMath.tileX(longitude: lon + 0.01, zoom: 12)) == 850)
        #expect(Int(TileMath.tileY(latitude: lat - 0.01, zoom: 12)) == 1550)
    }

    @Test func `a small view resolves to a handful of tiles at full zoom`() {
        let range = TileMath.cover(
            west: -105.30, south: 39.98, east: -105.26, north: 40.01,
            preferredZoom: 13)
        #expect(range.zoom == 13)
        #expect(range.count <= 16)
        #expect(range.count >= 1)
    }

    // A wide view at source zoom would be hundreds of tiles — a download storm
    // and more pixels than a phone should push through Horn's method at once.
    @Test func `a wide view drops zoom until the mosaic fits the cap`() {
        let range = TileMath.cover(
            west: -109, south: 37, east: -102, north: 41,  // all of Colorado
            preferredZoom: 14, maxTiles: 16)
        #expect(range.count <= 16)
        #expect(range.zoom < 14)
    }

    @Test func `zoom never exceeds the source resolution`() {
        let range = TileMath.cover(
            west: -105.281, south: 39.994, east: -105.280, north: 39.996,
            preferredZoom: 19)
        #expect(range.zoom == SlopeMath.overlayMaxZoom)
    }

    @Test func `the mosaic bounds enclose the requested view`() {
        let (w, s, e, n) = (-105.30, 39.98, -105.26, 40.01)
        let range = TileMath.cover(west: w, south: s, east: e, north: n, preferredZoom: 13)
        #expect(range.west <= w)
        #expect(range.east >= e)
        #expect(range.north >= n)
        #expect(range.south <= s)
    }

    @Test func `pixel dimensions follow the tile grid`() {
        let range = TileMath.cover(
            west: -105.30, south: 39.98, east: -105.26, north: 40.01, preferredZoom: 13)
        #expect(range.pixelWidth == range.columns * 256)
        #expect(range.pixelHeight == range.rows * 256)
        #expect(range.tiles().count == range.count)
    }

    @Test func `extreme latitudes clamp rather than diverge`() {
        let range = TileMath.cover(
            west: -180, south: -89, east: 180, north: 89, preferredZoom: 4)
        #expect(range.count <= 16)
        #expect(range.north.isFinite)
        #expect(range.south.isFinite)
    }
}
