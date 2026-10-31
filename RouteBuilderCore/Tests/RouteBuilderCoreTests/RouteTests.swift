import Foundation
import Testing
@testable import RouteBuilderCore

@Suite("Route stats match the web app")
struct RouteStatsTests {

    @Test func `distance and gain over a short climb`() {
        let track = [
            Coordinate(longitude: -105.2811, latitude: 39.9992, elevation: 1760),
            Coordinate(longitude: -105.2850, latitude: 39.9950, elevation: 1820),
            Coordinate(longitude: -105.2928, latitude: 39.9865, elevation: 2100),
        ]
        let stats = RouteState.stats(for: track)
        #expect(abs(stats.distanceMiles - 1.074037385) < 1e-9)
        #expect(abs(stats.gainFeet - 1115.4856) < 1e-6)
    }

    @Test func `a monotonic staircase accumulates every step`() {
        let stair = (0..<50).map {
            Coordinate(longitude: -105 + Double($0) * 0.001, latitude: 40,
                       elevation: 2000 + Double($0) * 10)
        }
        let stats = RouteState.stats(for: stair)
        #expect(abs(stats.distanceMiles - 2.593499294) < 1e-9)
        #expect(abs(stats.gainFeet - 1607.6116) < 1e-6)
    }

    // The hysteresis guards against one-sided DEM drift, not oscillation:
    // +/-2 m swings are 4 m peak to peak, which clears the 3 m gate every
    // time. The web app reports 1312 ft of gain across 200 points of dead
    // flat ground, and this port reports the same number on purpose. Pinned
    // here so that if the threshold is ever revisited, the test says plainly
    // what the old behaviour was.
    @Test func `oscillating noise clears the hysteresis gate, as in the web app`() {
        let noisy = (0..<200).map {
            Coordinate(longitude: -105 + Double($0) * 0.0001, latitude: 40,
                       elevation: 2000 + ($0.isMultiple(of: 2) ? -2 : 2))
        }
        let stats = RouteState.stats(for: noisy)
        #expect(abs(stats.distanceMiles - 1.053278285) < 1e-9)
        #expect(abs(stats.gainFeet - 1312.336) < 1e-6)
    }

    @Test func `descent alone produces no gain`() {
        let down = (0..<40).map {
            Coordinate(longitude: -105 + Double($0) * 0.001, latitude: 40,
                       elevation: 3000 - Double($0) * 25)
        }
        #expect(RouteState.stats(for: down).gainFeet == 0)
    }

    @Test func `an empty track is all zeroes`() {
        #expect(RouteState.stats(for: []) == .zero)
    }

    @Test func `missing elevations are treated as the running reference`() {
        // A gap must not read as sea level and invent 6,000 ft of descent.
        let gapped = [
            Coordinate(longitude: -105.0, latitude: 40, elevation: 2000),
            Coordinate(longitude: -105.001, latitude: 40, elevation: nil),
            Coordinate(longitude: -105.002, latitude: 40, elevation: 2000),
        ]
        #expect(RouteState.stats(for: gapped).gainFeet == 0)
    }
}

@Suite("Route state assembly")
struct RouteStateTests {

    private func leg(_ elevations: [Double], from startLon: Double) -> Leg {
        Leg(
            coordinates: elevations.enumerated().map { index, elevation in
                Coordinate(longitude: startLon + Double(index) * 0.001,
                           latitude: 40, elevation: elevation)
            },
            isStraight: false
        )
    }

    @Test func `legs stitch without duplicating their shared joint`() {
        let first = leg([2000, 2010, 2020], from: -105.000)
        let second = leg([2020, 2030, 2040], from: -105.002)
        let state = RouteState(waypoints: [], legs: [first, second])
        // 3 + 3 points, minus the one joint they share.
        #expect(state.track.count == 5)
        #expect(state.track.map(\.elevation) == [2000, 2010, 2020, 2030, 2040])
    }

    @Test func `nil legs awaiting a rebuild are skipped`() {
        let state = RouteState(waypoints: [], legs: [leg([2000, 2010], from: -105), nil])
        #expect(state.track.count == 2)
    }

    @Test func `an empty route has an empty track`() {
        #expect(RouteState().track.isEmpty)
        #expect(RouteState().isEmpty)
    }

    @Test func `state is a value, so a copy is an undo snapshot`() {
        var state = RouteState(waypoints: [Coordinate(longitude: -105, latitude: 40)])
        let snapshot = state
        state.waypoints.append(Coordinate(longitude: -106, latitude: 41))
        #expect(snapshot.waypoints.count == 1)
        #expect(state.waypoints.count == 2)
    }

    @Test func `state round-trips through Codable for saved routes`() throws {
        let original = RouteState(
            waypoints: [Coordinate(longitude: -105.28, latitude: 39.99, elevation: 1760)],
            legs: [leg([2000, 2010], from: -105)]
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RouteState.self, from: data) == original)
    }
}

@Suite("GPX export")
struct GPXTests {

    @Test func `track points carry six-decimal coordinates and elevation`() {
        let gpx = GPX.document(for: [
            Coordinate(longitude: -105.2811, latitude: 39.9992, elevation: 1760.44)
        ], name: "Royal Arch")
        #expect(gpx.contains(#"<trkpt lat="39.999200" lon="-105.281100"><ele>1760.4</ele></trkpt>"#))
        #expect(gpx.contains("<name>Royal Arch</name>"))
        #expect(gpx.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#))
    }

    @Test func `a point with no elevation omits the ele element`() {
        let gpx = GPX.document(for: [Coordinate(longitude: -105, latitude: 40)])
        #expect(gpx.contains(#"<trkpt lat="40.000000" lon="-105.000000"></trkpt>"#))
        #expect(!gpx.contains("<ele>"))
    }

    @Test func `route names are XML-escaped`() {
        let gpx = GPX.document(for: [], name: #"Bear & "Green" <Peak>"#)
        #expect(gpx.contains("Bear &amp; &quot;Green&quot; &lt;Peak&gt;"))
        #expect(!gpx.contains(#"<name>Bear & ""#))
    }

    @Test(arguments: [
        ("Royal Arch", "royal-arch.gpx"),
        ("  Bear Peak  ", "bear-peak.gpx"),
        ("Mt. Sanitas / Lion's Lair", "mt-sanitas-lions-lair.gpx"),
        ("", "route.gpx"),
        ("!!!", "route.gpx"),
    ])
    func `filenames are slugified`(name: String, expected: String) {
        #expect(GPX.filename(for: name) == expected)
    }
}
