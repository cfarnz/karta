import Foundation
import Testing
@testable import RouteBuilderCore

/// Expected values came from running summary.js's own arithmetic under node.
@Suite("Point terrain matches the web app")
struct TerrainTests {

    @Test func `the 3x3 sample grid lands on the same ground`() {
        let grid = TerrainMath.sampleGrid(
            around: Coordinate(longitude: -105.2811, latitude: 39.9992), spacingM: 30)
        #expect(grid.count == 9)

        // Rows north to south, columns west to east — the order Horn expects.
        #expect(abs(grid[0].longitude - -105.281451794) < 1e-9)
        #expect(abs(grid[0].latitude - 39.999469493) < 1e-9)
        #expect(abs(grid[4].longitude - -105.281100000) < 1e-9)
        #expect(abs(grid[4].latitude - 39.999200000) < 1e-9)
        #expect(abs(grid[8].longitude - -105.280748206) < 1e-9)
        #expect(abs(grid[8].latitude - 39.998930507) < 1e-9)

        // The centre sample is the point itself.
        #expect(grid[4].latitude == 39.9992)
    }

    private func sample(_ z: [Double], _ spacing: Double)
        -> (slope: Double, aspect: Double?) {
        let g = TerrainMath.gradients(elevations: z, spacingM: spacing)!
        let slope = TerrainMath.slopeDegrees(dzdx: g.dzdx, dzdy: g.dzdy)
        let aspect = slope < TerrainMath.flatBelowDegrees
            ? nil
            : SlopeMath.aspectDegrees(dzdx: g.dzdx, dzdy: g.dzdy)
                .truncatingRemainder(dividingBy: 360)
        return (slope, aspect)
    }

    // Elevation rises to the east, so the slope faces west — downhill.
    @Test func `a plane rising eastward faces west at 45 degrees`() {
        let g = TerrainMath.gradients(
            elevations: [2000, 2030, 2060, 2000, 2030, 2060, 2000, 2030, 2060],
            spacingM: 30)!
        #expect(abs(g.dzdx - 1.0) < 1e-12)
        #expect(abs(g.dzdy - 0.0) < 1e-12)

        let s = sample([2000, 2030, 2060, 2000, 2030, 2060, 2000, 2030, 2060], 30)
        #expect(abs(s.slope - 45) < 1e-9)
        #expect(abs((s.aspect ?? -1) - 270) < 1e-9)
        #expect(TerrainMath.compass(s.aspect!) == "W")
        #expect(SlopeBand.of(s.slope) == .avalanche)
    }

    @Test func `a plane falling southward faces south`() {
        let s = sample([2060, 2060, 2060, 2030, 2030, 2030, 2000, 2000, 2000], 30)
        #expect(abs(s.slope - 45) < 1e-9)
        #expect(abs((s.aspect ?? -1) - 180) < 1e-9)
        #expect(TerrainMath.compass(s.aspect!) == "S")
    }

    // The coarse provider samples 90 m apart, which changes the gradient for
    // the same elevation differences.
    @Test func `a north-west face at 90 metre spacing`() {
        let s = sample([1800, 1850, 1900, 1850, 1900, 1950, 1900, 1950, 2000], 90)
        #expect(abs(s.slope - 38.1558065387) < 1e-9)
        #expect(abs((s.aspect ?? -1) - 315) < 1e-9)
        #expect(TerrainMath.compass(s.aspect!) == "NW")
        #expect(SlopeBand.of(s.slope) == .avalanche)
    }

    // Flat ground has no meaningful aspect; pointing confidently at a
    // direction derived from DEM jitter would be worse than saying nothing.
    @Test func `dead flat ground reports no aspect`() {
        let s = sample(Array(repeating: 2000, count: 9), 30)
        #expect(s.slope == 0)
        #expect(s.aspect == nil)
        #expect(SlopeBand.of(s.slope) == .low)
    }

    @Test func `a malformed window yields no gradients rather than garbage`() {
        #expect(TerrainMath.gradients(elevations: [1, 2, 3], spacingM: 30) == nil)
        #expect(TerrainMath.gradients(elevations: Array(repeating: 0, count: 9),
                                      spacingM: 0) == nil)
    }

    // ---------- compass ----------

    @Test func `the compass matches the web app at every boundary`() {
        let expected: [(Double, String)] = [
            (0, "N"), (11.24, "N"), (11.26, "NNE"), (22.5, "NNE"),
            (45, "NE"), (90, "E"), (180, "S"), (270, "W"),
            (337.5, "NNW"), (350, "N"), (359.9, "N"),
        ]
        for (degrees, point) in expected {
            #expect(TerrainMath.compass(degrees) == point)
        }
    }

    // Wind direction arrives straight from a provider, and a negative bearing
    // would index out of the table rather than wrapping.
    @Test func `a negative bearing wraps instead of crashing`() {
        #expect(TerrainMath.compass(-90) == "W")
        #expect(TerrainMath.compass(-1) == "N")
        #expect(TerrainMath.compass(720) == "N")
    }

    // ---------- slope bands ----------

    @Test func `the avalanche band is inclusive at both ends`() {
        let expected: [(Double, SlopeBand)] = [
            (0, .low), (29.9, .low), (30, .avalanche), (37, .avalanche),
            (45, .avalanche), (45.1, .steep), (60, .steep),
        ]
        for (degrees, band) in expected {
            #expect(SlopeBand.of(degrees) == band)
        }
        #expect(SlopeBand.of(37).note != nil)
        #expect(SlopeBand.of(10).note == nil)
        #expect(SlopeBand.of(50).note == nil)
    }
}
