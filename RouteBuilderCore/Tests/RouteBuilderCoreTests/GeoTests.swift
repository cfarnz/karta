import Testing
@testable import RouteBuilderCore

// Expected values in this file were produced by running the original
// JavaScript (src/router.js, src/route.js, src/discover.js) under node, not by
// recomputing the formulas here. A port that merely agrees with my arithmetic
// proves nothing; one that agrees with the shipping web app proves the move
// did not change anyone's mileage.

private let chautauqua = Coordinate(longitude: -105.2811, latitude: 39.9992)
private let royalArch = Coordinate(longitude: -105.2928, latitude: 39.9865)

@Suite("Geodesy matches the web app")
struct GeoTests {

    @Test func `haversine over a short trail segment`() {
        #expect(abs(chautauqua.distance(to: royalArch) - 1728.489891) < 1e-5)
    }

    @Test func `haversine over hundreds of kilometres`() {
        let denver = Coordinate(longitude: -104.9903, latitude: 39.7392)
        let telluride = Coordinate(longitude: -107.8123, latitude: 37.9375)
        #expect(abs(denver.distance(to: telluride) - 316_001.887973) < 1e-3)
    }

    @Test func `a point is zero distance from itself`() {
        #expect(chautauqua.distance(to: chautauqua) == 0)
    }

    @Test func `sub-metre distances survive the asin`() {
        let a = Coordinate(longitude: -105.0, latitude: 40.0)
        let b = Coordinate(longitude: -105.00001, latitude: 40.0)
        #expect(abs(a.distance(to: b) - 0.851802557) < 1e-7)
    }

    @Test func `distance is symmetric`() {
        #expect(chautauqua.distance(to: royalArch) == royalArch.distance(to: chautauqua))
    }

    @Test func `track length sums its segments`() {
        let track = [
            Coordinate(longitude: -105.2811, latitude: 39.9992, elevation: 1760),
            Coordinate(longitude: -105.2850, latitude: 39.9950, elevation: 1820),
            Coordinate(longitude: -105.2928, latitude: 39.9865, elevation: 2100),
        ]
        #expect(abs(track.trackLengthM - 1728.495622) < 1e-5)
    }

    @Test func `track length of a single point is zero`() {
        #expect([chautauqua].trackLengthM == 0)
        #expect([Coordinate]().trackLengthM == 0)
    }

    @Test func `offset north-east by five kilometres`() {
        let p = chautauqua.offset(bearingDegrees: 45, distanceM: 5000)
        #expect(abs(p.longitude - -105.239574654) < 1e-9)
        #expect(abs(p.latitude - 40.030988413) < 1e-9)
    }

    @Test func `offset due west by twelve kilometres`() {
        let p = chautauqua.offset(bearingDegrees: 270, distanceM: 12000)
        #expect(abs(p.longitude - -105.421975950) < 1e-9)
        #expect(abs(p.latitude - 39.999114721) < 1e-9)
    }

    @Test func `offset then measure returns the distance travelled`() {
        let p = chautauqua.offset(bearingDegrees: 123, distanceM: 8000)
        #expect(abs(chautauqua.distance(to: p) - 8000) < 1e-6)
    }
}
