import Foundation
import Testing
@testable import RouteBuilderCore

/// Every expected value here came from running the shipping web app's own
/// `profile.js` arithmetic under node, not from re-deriving it in Swift.
/// Agreeing with fresh arithmetic would only prove the Swift is self
/// consistent; agreeing with the deployed numbers proves nobody's profile
/// changed shape in the port.
@Suite("Elevation profile matches the web app")
struct ElevationProfileTests {

    private static let climb = [
        Coordinate(longitude: -105.2811, latitude: 39.9992, elevation: 1760),
        Coordinate(longitude: -105.2850, latitude: 39.9950, elevation: 1820),
        Coordinate(longitude: -105.2928, latitude: 39.9865, elevation: 2100),
    ]

    private static let staircase = (0..<50).map {
        Coordinate(longitude: -105 + Double($0) * 0.001, latitude: 40,
                   elevation: 2000 + Double($0) * 10)
    }

    @Test func `cumulative distance and feet match profile.js`() {
        let profile = ElevationProfile(track: Self.climb)
        #expect(profile.points.count == 3)

        #expect(profile.points[0].distanceMiles == 0)
        #expect(abs(profile.points[1].distanceMiles - 0.356124664479) < 1e-12)
        #expect(abs(profile.points[2].distanceMiles - 1.074037385299) < 1e-12)

        #expect(abs(profile.points[0].elevationFeet - 5774.2784) < 1e-8)
        #expect(abs(profile.points[1].elevationFeet - 5971.1288) < 1e-8)
        #expect(abs(profile.points[2].elevationFeet - 6889.7640) < 1e-8)
    }

    @Test func `the final cumulative distance agrees with route stats`() {
        // The chart's x-axis and the stats bar's DIST read the same track, so
        // a reader who sees 1.07 mi on one and 1.09 on the other is looking at
        // a bug. Pinned because they are computed by separate code paths.
        let profile = ElevationProfile(track: Self.staircase)
        let stats = RouteState.stats(for: Self.staircase)
        #expect(abs(profile.distanceRange.upperBound - stats.distanceMiles) < 1e-12)
        #expect(abs(profile.distanceRange.upperBound - 2.593499293671) < 1e-12)
    }

    @Test func `the axis domains match profile.js`() {
        let profile = ElevationProfile(track: Self.staircase)
        #expect(profile.distanceRange.lowerBound == 0)
        #expect(abs(profile.elevationRange.lowerBound - 6561.68) < 1e-8)
        #expect(abs(profile.elevationRange.upperBound - 8169.2916) < 1e-8)
    }

    // A valley-floor route has a few feet of DEM noise. Scaled to the plot
    // height that reads as a mountain stage, so the span opens out to 100 ft.
    @Test func `a flat route widens to the hundred foot floor`() {
        let flat = (0..<20).map {
            Coordinate(longitude: -105 + Double($0) * 0.001, latitude: 40,
                       elevation: 2000 + ($0.isMultiple(of: 2) ? 0 : 1))
        }
        let profile = ElevationProfile(track: flat)
        #expect(abs(profile.elevationRange.lowerBound - 6561.68) < 1e-8)
        #expect(abs(profile.elevationRange.upperBound - 6661.68) < 1e-8)
        #expect(abs((profile.elevationRange.upperBound
                     - profile.elevationRange.lowerBound) - 100) < 1e-8)
        #expect(abs(profile.distanceRange.upperBound - 1.005642583260) < 1e-12)
    }

    @Test func `an unsampled point reads as zero, as in the web app`() {
        let gap = [
            Coordinate(longitude: -105, latitude: 40, elevation: 1000),
            Coordinate(longitude: -105.001, latitude: 40, elevation: nil),
            Coordinate(longitude: -105.002, latitude: 40, elevation: 1010),
        ]
        let profile = ElevationProfile(track: gap)
        #expect(abs(profile.points[0].elevationFeet - 3280.84) < 1e-8)
        #expect(profile.points[1].elevationFeet == 0)
        #expect(abs(profile.points[2].elevationFeet - 3313.6484) < 1e-8)
        #expect(profile.elevationRange.lowerBound == 0)
    }

    // ---------- degenerate tracks ----------

    @Test func `fewer than two points is empty rather than a degenerate chart`() {
        #expect(ElevationProfile(track: []).isEmpty)
        #expect(ElevationProfile(track: [Self.climb[0]]).isEmpty)
        #expect(ElevationProfile(track: []).points.isEmpty)
    }

    // Swift Charts cannot scale an empty domain, and a route whose waypoints
    // all landed on the same spot produces one.
    @Test func `a zero length track still has a drawable x domain`() {
        let stacked = Array(repeating: Coordinate(longitude: -105, latitude: 40,
                                                  elevation: 2000), count: 4)
        let profile = ElevationProfile(track: stacked)
        #expect(profile.distanceRange.upperBound == 1)
        #expect(profile.elevationRange.upperBound > profile.elevationRange.lowerBound)
    }

    // ---------- scrubbing ----------

    @Test func `scrubbing lands on the same point profile.js hover picked`() {
        let profile = ElevationProfile(track: Self.staircase)
        let expected: [(Double, Double, Double)] = [
            (0,              0.000000000000, 6561.68000),
            (0.5,            0.476357013123, 6856.95560),
            (1.0,            1.005642583260, 7185.03960),
            (1.2965,         1.270285368329, 7349.08160),
            (2.0,            2.011285166520, 7808.39920),
            (2.5934992941,   2.593499293671, 8169.29160),
            (99,             2.593499293671, 8169.29160),  // past the end, clamped
        ]
        for (query, distance, elevation) in expected {
            let point = profile.point(nearestTo: query)
            #expect(point != nil)
            #expect(abs((point?.distanceMiles ?? -1) - distance) < 1e-12)
            #expect(abs((point?.elevationFeet ?? -1) - elevation) < 1e-5)
        }
    }

    // The binary search is only valid because cumulative distance never
    // decreases. If that ever stops holding, this is the test that says so.
    @Test func `the binary search agrees with the linear scan everywhere`() {
        let profile = ElevationProfile(track: Self.staircase)
        let total = profile.distanceRange.upperBound
        for step in 0...400 {
            let query = total * Double(step) / 400
            let scanned = profile.points.min {
                abs($0.distanceMiles - query) < abs($1.distanceMiles - query)
            }
            #expect(profile.point(nearestTo: query) == scanned)
        }
    }

    @Test func `a fraction across the plot clamps at both ends`() {
        let profile = ElevationProfile(track: Self.staircase)
        #expect(profile.point(atFraction: -3) == profile.points.first)
        #expect(profile.point(atFraction: 4) == profile.points.last)
        #expect(profile.point(atFraction: 0) == profile.points.first)
        #expect(profile.point(atFraction: 1) == profile.points.last)
    }

    @Test func `scrubbing an empty profile returns nothing rather than crashing`() {
        #expect(ElevationProfile.empty.point(nearestTo: 1) == nil)
        #expect(ElevationProfile.empty.point(atFraction: 0.5) == nil)
    }

    @Test func `the scrub carries the ground position for the map cursor`() {
        let profile = ElevationProfile(track: Self.climb)
        let last = profile.point(atFraction: 1)
        #expect(last?.coordinate == Self.climb[2])
    }

    @Test func `the high and low readouts match the sampled extremes`() {
        let profile = ElevationProfile(track: Self.staircase)
        #expect(abs(profile.lowestFeet - 6561.68) < 1e-8)
        #expect(abs(profile.highestFeet - 8169.2916) < 1e-8)
    }
}
