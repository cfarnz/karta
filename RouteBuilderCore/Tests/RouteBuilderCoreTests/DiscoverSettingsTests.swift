import Foundation
import Testing
@testable import RouteBuilderCore

@Suite("Discover settings match the web app's controls")
struct DiscoverSettingsTests {

    // The defaults are what the search runs with when the user taps Find
    // without touching anything, so they are part of the behaviour.
    @Test func `the defaults match the web app's slider values`() {
        let settings = DiscoverSettings()
        #expect(settings.targetMiles == 10)
        #expect(settings.maxEffort == 20)
        #expect(settings.highPointMinFt == 5_000)
        #expect(settings.highPointMaxFt == 14_500)
        #expect(settings.radiusMiles == 20)
        #expect(settings.mountainsOnly == false)
    }

    @Test func `the slider bounds match the web app's inputs`() {
        #expect(DiscoverSettings.targetRange == 2...30)
        #expect(DiscoverSettings.effortRange == 5...45)
        #expect(DiscoverSettings.highPointLimits == 4_000...14_500)
        #expect(DiscoverSettings.radiusRange == 2...120)
        #expect(DiscoverSettings.highPointStep == 500)
        #expect(DiscoverSettings.radiusStep == 2)
    }

    // Dragging the low handle above the high one should mean what it looks
    // like rather than filtering everything out.
    @Test func `crossed high point handles are sorted, not empty`() {
        var settings = DiscoverSettings()
        settings.highPointMinFt = 12_000
        settings.highPointMaxFt = 6_000
        #expect(settings.highPointRange == 6_000...12_000)

        let options = settings.options(center: Coordinate(longitude: -105, latitude: 40))
        #expect(options.highPointMinFt == 6_000)
        #expect(options.highPointMaxFt == 12_000)
    }

    @Test func `uncrossed handles pass straight through`() {
        var settings = DiscoverSettings()
        settings.highPointMinFt = 8_000
        settings.highPointMaxFt = 13_000
        #expect(settings.highPointRange == 8_000...13_000)
    }

    @Test func `equal handles are a valid single value range`() {
        var settings = DiscoverSettings()
        settings.highPointMinFt = 9_000
        settings.highPointMaxFt = 9_000
        #expect(settings.highPointRange == 9_000...9_000)
    }

    @Test func `the difficulty label pairs the bucket with the raw score`() {
        var settings = DiscoverSettings()
        for (score, expected) in [(5.0, "Easy (5)"), (7.0, "Easy (7)"),
                                  (8.0, "Moderate (8)"), (13.0, "Moderate (13)"),
                                  (14.0, "Hard (14)"), (19.0, "Hard (19)"),
                                  (20.0, "Very Hard (20)"), (45.0, "Very Hard (45)")] {
            settings.maxEffort = score
            #expect(settings.effortLabel == expected)
        }
    }

    @Test func `every other slider reaches the service unchanged`() {
        var settings = DiscoverSettings()
        settings.targetMiles = 14
        settings.maxEffort = 30
        settings.radiusMiles = 60
        settings.mountainsOnly = true

        let center = Coordinate(longitude: -105.28, latitude: 39.99)
        let options = settings.options(center: center)
        #expect(options.center == center)
        #expect(options.targetMiles == 14)
        #expect(options.maxEffort == 30)
        #expect(options.radiusMiles == 60)
        #expect(options.mountainsOnly)
    }
}
