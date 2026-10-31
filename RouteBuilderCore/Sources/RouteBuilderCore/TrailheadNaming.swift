import Foundation

/// Giving a trailhead a name a human would recognise.
///
/// About a third of OSM's `highway=trailhead` nodes around Boulder carry no
/// `name` tag at all, and a handful carry worse than none — `Gen10`, `Gen13`
/// and friends are GPS waypoint labels from a bulk import, which look
/// deliberate and so read as more trustworthy than they are.
///
/// The name is almost always sitting next to the node: the same cluster
/// labelled `Gen06`..`Gen13` is inside **Genesee Mountain Park**, and the
/// blank node above Boulder is at the foot of the **Dakota Ridge Trail**. So
/// this resolves a name from nearby named features rather than reaching for
/// a third-party trail database.
public enum TrailheadNaming {

    /// The placeholder used when OSM gives us nothing.
    public static let placeholder = "Trailhead"

    /// How far to look for a name, in metres, in four tiers.
    ///
    /// Measured against the ten unnamed trailheads within 20 miles of
    /// Boulder: the near tiers alone name 9 of 10, and adding the far tiers
    /// names all 10. So the query asks at the far radius — one request — and
    /// `bestName` prefers the tightest match, because a path 40 m away is
    /// almost certainly the trail the node serves while one 400 m away is a
    /// guess worth making only when nothing closer exists.
    public static let nearPathRadiusM = 150.0
    public static let nearAreaRadiusM = 500.0
    public static let farPathRadiusM = 400.0
    public static let farAreaRadiusM = 1_500.0

    /// Path types worth borrowing a name from. Deliberately excludes roads:
    /// "3rd Street" is a real name and a useless trailhead.
    static let pathValues = ["path", "footway", "track", "bridleway", "cycleway"]

    /// True when a name tells the user nothing, so it is worth replacing.
    ///
    /// Two cases: the literal placeholder, and machine-generated labels. The
    /// machine test is "a single word containing a digit" — `Gen10`, `WPT001`,
    /// `TH3` — which no real trailhead name looks like, while single-word
    /// real names (`Chautauqua`) have no digits and multi-word names are
    /// always kept.
    public static func isUninformative(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(placeholder) == .orderedSame {
            return true
        }
        let hasWhitespace = trimmed.contains { $0.isWhitespace }
        let hasDigit = trimmed.contains { $0.isNumber }
        return !hasWhitespace && hasDigit
    }

    /// A candidate name found near a trailhead.
    public struct NearbyFeature: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A named trail. Preferred: it is what the trailhead leads to.
            case path
            /// A park or protected area. The fallback, and often the name
            /// people actually use.
            case area
        }
        public var name: String
        public var kind: Kind
        public var coordinate: Coordinate

        public init(name: String, kind: Kind, coordinate: Coordinate) {
            self.name = name
            self.kind = kind
            self.coordinate = coordinate
        }
    }

    /// One Overpass query covering every node that needs a name.
    ///
    /// Unioned rather than one request per node: a search picks at most a
    /// handful of anchors, and Overpass is rate-limited enough that six
    /// requests where one will do is a bad trade.
    public static func resolutionQuery(for points: [Coordinate]) -> String {
        let paths = pathValues.joined(separator: "|")
        let clauses = points.flatMap { point -> [String] in
            let latitude = String(format: "%.6f", point.latitude)
            let longitude = String(format: "%.6f", point.longitude)
            let near = { (radius: Double) in
                "(around:\(Int(radius)),\(latitude),\(longitude))"
            }
            // The widest radius of each kind: a superset, narrowed per tier
            // when the name is actually chosen.
            return [
                #"way["name"]["highway"~"^(\#(paths))$"]\#(near(farPathRadiusM));"#,
                #"way["name"]["boundary"="protected_area"]\#(near(farAreaRadiusM));"#,
                #"relation["name"]["boundary"="protected_area"]\#(near(farAreaRadiusM));"#,
                #"way["name"]["leisure"~"^(park|nature_reserve)$"]\#(near(farAreaRadiusM));"#,
            ]
        }.joined()

        // `center` so ways and relations come back with a single point to
        // measure against, rather than full geometry we would have to reduce.
        return "[out:json][timeout:25];(\(clauses));out tags center 200;"
    }

    /// Picks the best name for a point from the features the query returned.
    ///
    /// Four tiers, first non-empty one wins, nearest within it:
    ///
    /// 1. a trail within 150 m — "Dakota Ridge Trail", almost certainly the
    ///    trail this node serves
    /// 2. a park or protected area within 500 m — "Genesee Mountain Park",
    ///    less specific but reliable
    /// 3. a trail within 400 m — a guess, but a useful one
    /// 4. a park within 1500 m — last resort before giving up
    ///
    /// A close trail beats a close park because "Boulder Open Space and
    /// Mountain Parks" covers 45,000 acres and names nothing in particular.
    public static func bestName(
        for point: Coordinate, from features: [NearbyFeature]
    ) -> String? {
        let tiers: [(NearbyFeature.Kind, Double)] = [
            (.path, nearPathRadiusM),
            (.area, nearAreaRadiusM),
            (.path, farPathRadiusM),
            (.area, farAreaRadiusM),
        ]

        for (kind, radius) in tiers {
            let candidates = features.filter {
                $0.kind == kind && point.distance(to: $0.coordinate) <= radius
            }
            if let nearest = candidates.min(by: {
                point.distance(to: $0.coordinate) < point.distance(to: $1.coordinate)
            }) {
                return nearest.name
            }
        }
        return nil
    }
}

// ---------- wire format ----------

/// Overpass `out center` response. Ways and relations carry `center`; nodes
/// carry `lat`/`lon` directly.
struct OverpassCenterResponse: Codable {
    struct Center: Codable {
        var lat: Double
        var lon: Double
    }
    struct Element: Codable {
        var type: String?
        var lat: Double?
        var lon: Double?
        var center: Center?
        var tags: [String: String]?

        var coordinate: Coordinate? {
            if let center { return Coordinate(longitude: center.lon, latitude: center.lat) }
            if let lat, let lon { return Coordinate(longitude: lon, latitude: lat) }
            return nil
        }

        var feature: TrailheadNaming.NearbyFeature? {
            guard let name = tags?["name"], let coordinate else { return nil }
            let isPath = tags?["highway"].map {
                TrailheadNaming.pathValues.contains($0)
            } ?? false
            return TrailheadNaming.NearbyFeature(
                name: name, kind: isPath ? .path : .area, coordinate: coordinate)
        }
    }
    var elements: [Element]?
}

/// The cache stores Codable values, and `NearbyFeature` holds an enum and a
/// `Coordinate` that would otherwise need their own coding.
struct StoredFeature: Codable, Sendable {
    var name: String
    var isPath: Bool
    var longitude: Double
    var latitude: Double
}
