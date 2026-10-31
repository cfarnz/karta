import Foundation
import Testing
@testable import RouteBuilderCore

@Suite("CAIC zone lookup matches the web app")
struct AvalancheTests {

    private static let square: [[[Double]]] = [
        [[-106, 39], [-104, 39], [-104, 41], [-106, 41], [-106, 39]]
    ]
    private static let squareWithHole: [[[Double]]] = [
        [[-106, 39], [-104, 39], [-104, 41], [-106, 41], [-106, 39]],
        [[-105.5, 39.5], [-104.5, 39.5], [-104.5, 40.5], [-105.5, 40.5], [-105.5, 39.5]],
    ]

    private func point(_ lon: Double, _ lat: Double) -> Coordinate {
        Coordinate(longitude: lon, latitude: lat)
    }

    @Test func `a point inside a zone is found`() {
        #expect(GeoPolygon.contains(point(-105, 40), polygon: Self.square))
    }

    @Test func `a point outside a zone is not`() {
        #expect(!GeoPolygon.contains(point(-103, 40), polygon: Self.square))
        #expect(!GeoPolygon.contains(point(-105, 42), polygon: Self.square))
    }

    // The first ring is the outer boundary; the rest are holes.
    @Test func `a point inside a hole is outside the zone`() {
        #expect(!GeoPolygon.contains(point(-105, 40), polygon: Self.squareWithHole))
    }

    @Test func `a point between the boundary and a hole is inside`() {
        #expect(GeoPolygon.contains(point(-105.8, 40), polygon: Self.squareWithHole))
    }

    @Test func `a multipolygon matches on any of its parts`() {
        let second: [[[Double]]] = [
            [[-101, 45], [-100, 45], [-100, 46], [-101, 46], [-101, 45]]
        ]
        let geometry = try! JSONDecoder().decode(
            CAICGeometry.self,
            from: Data(#"{"type":"MultiPolygon","coordinates":[\#(Self.json(Self.square)),\#(Self.json(second))]}"#.utf8))

        #expect(GeoPolygon.contains(point(-100.5, 45.5), geometry: geometry))
        #expect(GeoPolygon.contains(point(-105, 40), geometry: geometry))
        #expect(!GeoPolygon.contains(point(-90, 20), geometry: geometry))
    }

    @Test func `a degenerate ring matches nothing rather than crashing`() {
        #expect(!GeoPolygon.contains(point(0, 0), ring: []))
        #expect(!GeoPolygon.contains(point(0, 0), ring: [[0, 0], [1, 1]]))
        #expect(!GeoPolygon.contains(point(0, 0), polygon: []))
    }

    @Test func `an unsupported geometry type matches nothing`() {
        let geometry = try! JSONDecoder().decode(
            CAICGeometry.self,
            from: Data(#"{"type":"Point","coordinates":[-105,40]}"#.utf8))
        #expect(!GeoPolygon.contains(point(-105, 40), geometry: geometry))
    }

    // ---------- off season ----------

    // CAIC returns one merged zone rated "no rating" out of season rather
    // than dropping the feed, so a blank card in July is correct.
    @Test func `the off season sentinel is recognised both ways`() {
        let byLevel = try! JSONDecoder().decode(
            CAICMapLayer.Feature.Properties.self,
            from: Data(#"{"name":"Colorado","danger_level":-1}"#.utf8))
        #expect(byLevel.isOffSeason)

        let byText = try! JSONDecoder().decode(
            CAICMapLayer.Feature.Properties.self,
            from: Data(#"{"name":"Colorado","danger":"no rating"}"#.utf8))
        #expect(byText.isOffSeason)

        let inSeason = try! JSONDecoder().decode(
            CAICMapLayer.Feature.Properties.self,
            from: Data(#"{"name":"Front Range","danger_level":2,"danger":"Moderate"}"#.utf8))
        #expect(!inSeason.isOffSeason)
    }

    @Test func `a warning is only surfaced when a product backs it`() {
        let withProduct = try! JSONDecoder().decode(
            CAICMapLayer.Feature.Properties.self,
            from: Data(#"{"name":"Vail","warning":{"product":"avalanche_warning","title":"Avalanche Warning"}}"#.utf8))
        #expect(withProduct.asZone().warningTitle == "Avalanche Warning")

        // A title with no product is leftover scaffolding in the feed.
        let titleOnly = try! JSONDecoder().decode(
            CAICMapLayer.Feature.Properties.self,
            from: Data(#"{"name":"Vail","warning":{"title":"Avalanche Warning"}}"#.utf8))
        #expect(titleOnly.asZone().warningTitle == nil)
    }

    @Test func `zone properties carry through to the card`() {
        let zone = try! JSONDecoder().decode(
            CAICMapLayer.Feature.Properties.self,
            // Deeper delimiter: the colour literal contains a `"#`, which
            // would close a single-hash raw string early.
            from: Data(##"{"name":"Front Range","danger_level":3,"danger":"Considerable","travel_advice":"Careful snowpack evaluation essential.","color":"#ff7e00"}"##.utf8)
        ).asZone()

        #expect(zone.zone == "Front Range")
        #expect(zone.level == 3)
        #expect(zone.danger == "Considerable")
        #expect(zone.travelAdvice == "Careful snowpack evaluation essential.")
        #expect(zone.color == "#ff7e00")
        #expect(!zone.isOffSeason)
    }

    private static func json(_ polygon: [[[Double]]]) -> String {
        let rings = polygon.map { ring in
            "[" + ring.map { "[\($0[0]),\($0[1])]" }.joined(separator: ",") + "]"
        }
        return "[" + rings.joined(separator: ",") + "]"
    }
}
