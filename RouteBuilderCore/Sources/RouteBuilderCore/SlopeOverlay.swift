import Foundation

// Terrain overlays: slope angle and aspect, computed from Terrarium DEM tiles.
//
// The web app registered a custom `slope://` MapLibre protocol for this.
// MapLibre Native has no raster equivalent, so the same maths lives here as
// pure functions and the platform layer decides how to get the pixels on
// screen. Keeping it free of UIKit is what makes it testable against the
// original JavaScript.

public struct RGB: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum TerrainOverlay: String, Sendable, CaseIterable, Identifiable {
    case slope
    case aspect

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .slope: "Slope"
        case .aspect: "Aspect"
        }
    }

    public var note: String {
        switch self {
        case .slope:
            "Loudest colours mark 30–45°, where most slab avalanches release."
        case .aspect:
            "Shown on slopes over \(Int(SlopeMath.aspectMinSlopeDegrees))°. "
                + "Flatter ground has no meaningful aspect."
        }
    }

    public var legend: [(label: String, color: RGB)] {
        switch self {
        case .slope:
            [
                ("27–30°", SlopeMath.slopeBands[0].color),
                ("30–35°", SlopeMath.slopeBands[1].color),
                ("35–40°", SlopeMath.slopeBands[2].color),
                ("40–45°", SlopeMath.slopeBands[3].color),
                ("45–50°", SlopeMath.slopeBands[4].color),
                ("50°+", SlopeMath.slopeBands[5].color),
            ]
        case .aspect:
            zip(["N", "NE", "E", "SE", "S", "SW", "W", "NW"], SlopeMath.aspectSectors)
                .map { ($0, $1) }
        }
    }
}

/// Terrarium elevation encoding, from AWS Open Data.
public enum Terrarium {
    /// Terrarium packs metres as (R * 256 + G + B / 256) - 32768.
    public static func elevation(red: UInt8, green: UInt8, blue: UInt8) -> Float {
        Float(Int(red) * 256 + Int(green)) + Float(blue) / 256 - 32768
    }

    /// Decode an RGBA buffer into metres, one value per pixel.
    public static func decode(rgba: [UInt8], width: Int, height: Int) -> [Float] {
        let count = width * height
        guard rgba.count >= count * 4 else { return [] }

        var out = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let p = index * 4
            out[index] = elevation(red: rgba[p], green: rgba[p + 1], blue: rgba[p + 2])
        }
        return out
    }
}

public enum SlopeMath {
    /// Terrarium publishes to z15. Past the source zoom the extra detail is
    /// interpolation, so overzoom rather than inventing terrain.
    public static let overlayMaxZoom = 14
    /// ~47%, enough to read contours through.
    public static let alpha: UInt8 = 120
    /// Flat ground has no meaningful aspect, so the overlay only paints
    /// terrain steep enough for the direction to mean something.
    public static let aspectMinSlopeDegrees = 20.0

    /// Most slab avalanches release between 30 and 45 degrees, so that range
    /// carries the loudest colours; below 27 stays clear so the topo
    /// underneath reads normally.
    public static let slopeBands: [(threshold: Double, color: RGB)] = [
        (27, RGB(242, 224, 74)),   // 27–30  yellow
        (30, RGB(240, 160, 60)),   // 30–35  orange
        (35, RGB(227, 79, 60)),    // 35–40  red, the heart of the slab band
        (40, RGB(186, 48, 92)),    // 40–45  deep red
        (45, RGB(138, 62, 158)),   // 45–50  purple
        (50, RGB(70, 78, 150)),    // 50+    blue
    ]

    /// Eight compass sectors on a colour wheel, so opposing aspects read as
    /// opposing colours. North is blue (holds snow, stays cold), south amber.
    public static let aspectSectors: [RGB] = [
        RGB(74, 127, 212),   // N
        RGB(70, 179, 196),   // NE
        RGB(79, 179, 106),   // E
        RGB(168, 188, 74),   // SE
        RGB(224, 168, 60),   // S
        RGB(224, 102, 60),   // SW
        RGB(201, 73, 143),   // W
        RGB(131, 85, 196),   // NW
    ]

    /// Ground distance covered by one pixel, which is the cell size Horn's
    /// method needs. Web Mercator stretches with latitude, so this varies.
    public static func metersPerPixel(zoom: Int, tileY: Double, tilePixels: Int) -> Double {
        let n = Double.pi - (2 * Double.pi * (tileY + 0.5)) / pow(2, Double(zoom))
        let latitude = atan(sinh(n))
        return (156_543.03392804097 * cos(latitude))
            / pow(2, Double(zoom))
            / (Double(tilePixels) / 256)
    }

    /// Ground metres per pixel at a latitude, for 256-pixel tiles.
    ///
    /// The tile-indexed version above evaluates at a tile's centre, which is
    /// what the web app used because it rendered one tile at a time. A
    /// stitched mosaic spans enough latitude that the Mercator stretch is
    /// worth following row by row, and this is the form that allows it.
    public static func metersPerPixel(latitude: Double, zoom: Int) -> Double {
        156_543.03392804097 * cos(latitude * .pi / 180) / pow(2, Double(zoom))
    }

    public static func slopeColor(degrees: Double) -> RGB? {
        guard degrees >= slopeBands[0].threshold else { return nil }
        for band in slopeBands.reversed() where degrees >= band.threshold {
            return band.color
        }
        return nil
    }

    /// ESRI's aspect convention: 0 is north, increasing clockwise.
    ///
    /// Shared with the location card, which runs the same Horn gradients over
    /// a 3x3 grid of sampled elevations rather than a tile of pixels. One
    /// implementation so the overlay and the card can never disagree about
    /// which way a slope faces.
    public static func aspectDegrees(dzdx: Double, dzdy: Double) -> Double {
        var a = atan2(dzdy, -dzdx) * 180 / .pi
        if a < 0 {
            a = 90 - a
        } else if a > 90 {
            a = 360 - a + 90
        } else {
            a = 90 - a
        }
        return a
    }

    public static func aspectSector(degrees: Double, dzdx: Double, dzdy: Double) -> Int? {
        guard degrees >= aspectMinSlopeDegrees else { return nil }
        let a = aspectDegrees(dzdx: dzdx, dzdy: dzdy)
        return Int((a.truncatingRemainder(dividingBy: 360) / 45).rounded()) % 8
    }

    public static func aspectColor(degrees: Double, dzdx: Double, dzdy: Double) -> RGB? {
        aspectSector(degrees: degrees, dzdx: dzdx, dzdy: dzdy).map { aspectSectors[$0] }
    }
}

/// A rectangular block of elevations in metres, row-major, north-west first.
public struct ElevationGrid: Sendable {
    public var width: Int
    public var height: Int
    public var values: [Float]

    public init(width: Int, height: Int, values: [Float]) {
        self.width = width
        self.height = height
        self.values = values
    }

    /// Clamped sample. Edges repeat the nearest in-grid pixel.
    @inline(__always)
    func at(_ x: Int, _ y: Int) -> Double {
        let cx = min(width - 1, max(0, x))
        let cy = min(height - 1, max(0, y))
        return Double(values[cy * width + cx])
    }
}

public enum OverlayRenderer {
    /// Render an overlay to RGBA bytes, one pixel per grid cell.
    ///
    /// `cellSizeForRow` supplies the ground distance per pixel at a given row.
    /// It is a closure rather than a constant because the web app computed one
    /// value per tile, while a stitched mosaic spans enough latitude that the
    /// Mercator stretch is worth following row by row.
    public static func render(
        grid: ElevationGrid,
        overlay: TerrainOverlay,
        cellSizeForRow: (Int) -> Double
    ) -> [UInt8] {
        let width = grid.width
        let height = grid.height
        guard width > 0, height > 0, grid.values.count == width * height else { return [] }

        var out = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            let cell = cellSizeForRow(y)
            guard cell > 0 else { continue }

            for x in 0..<width {
                let a = grid.at(x - 1, y - 1)
                let b = grid.at(x, y - 1)
                let c = grid.at(x + 1, y - 1)
                let d = grid.at(x - 1, y)
                let f = grid.at(x + 1, y)
                let g = grid.at(x - 1, y + 1)
                let h = grid.at(x, y + 1)
                let i = grid.at(x + 1, y + 1)

                let dzdx = (c + 2 * f + i - (a + 2 * d + g)) / (8 * cell)
                let dzdy = (g + 2 * h + i - (a + 2 * b + c)) / (8 * cell)
                let degrees = atan((dzdx * dzdx + dzdy * dzdy).squareRoot()) * 180 / .pi

                let color: RGB? = switch overlay {
                case .slope: SlopeMath.slopeColor(degrees: degrees)
                case .aspect: SlopeMath.aspectColor(degrees: degrees, dzdx: dzdx, dzdy: dzdy)
                }
                guard let color else { continue }  // leave it transparent

                let p = (y * width + x) * 4
                out[p] = color.red
                out[p + 1] = color.green
                out[p + 2] = color.blue
                out[p + 3] = SlopeMath.alpha
            }
        }
        return out
    }
}
