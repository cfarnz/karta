import Foundation

/// GPX 1.1 serialisation.
///
/// Track points carry elevation so COROS and Gaia show a real profile rather
/// than a flat line.
public enum GPX {
    public static func document(for coordinates: [Coordinate], name: String = "Route") -> String {
        let points = coordinates
            .map { trkpt($0, timestamp: nil, indent: "      ") }
            .joined(separator: "\n")

        let escaped = escape(name)

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="route-builder" xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata><name>\(escaped)</name></metadata>
          <trk>
            <name>\(escaped)</name>
            <trkseg>
        \(points)
            </trkseg>
          </trk>
        </gpx>

        """
    }

    // ---------- recordings ----------

    /// A recorded track, one <trkseg> per unbroken run of recording.
    ///
    /// Multiple segments inside a single <trk> is precisely what the GPX spec
    /// has trkseg for, and every other tool reads it that way, so a pause
    /// survives the round trip instead of being flattened into one continuous
    /// line that claims the user walked through the gap.
    ///
    /// Bridged gaps are deliberately **not** written as trkpts. A bridge is
    /// our estimate; written as track points it would be indistinguishable
    /// from measured GPS forever after, in this app and in every other one.
    /// The estimate stays in Karta's own storage, where it is labelled.
    public static func document(for track: Track, name: String? = nil) -> String {
        let escaped = escape(name ?? track.name)
        let segments = track.segments
            .filter { !$0.points.isEmpty }
            .map { segment -> String in
                let points = segment.points
                    .map { trkpt($0.coordinate, timestamp: $0.timestamp, indent: "        ") }
                    .joined(separator: "\n")
                return "      <trkseg>\n\(points)\n      </trkseg>"
            }
            .joined(separator: "\n")

        let time = track.firstPoint.map { "<time>\(iso8601($0.timestamp))</time>" } ?? ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="karta" xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata><name>\(escaped)</name>\(time)</metadata>
          <trk>
            <name>\(escaped)</name>
        \(segments)
          </trk>
        </gpx>

        """
    }

    /// One trkpt. Child order is fixed by the schema: ele before time.
    static func trkpt(_ coordinate: Coordinate, timestamp: Date?, indent: String) -> String {
        let lat = String(format: "%.6f", coordinate.latitude)
        let lon = String(format: "%.6f", coordinate.longitude)
        let elevation = coordinate.elevation.map {
            "<ele>\(String(format: "%.1f", $0))</ele>"
        } ?? ""
        let time = timestamp.map { "<time>\(iso8601($0))</time>" } ?? ""
        return #"\#(indent)<trkpt lat="\#(lat)" lon="\#(lon)">\#(elevation)\#(time)</trkpt>"#
    }

    /// GPX wants UTC with a Z, not a local offset.
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Filename slug: word characters, spaces and hyphens survive; spaces
    /// collapse to hyphens.
    public static func filename(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "route" : trimmed
        let kept = base.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == " "
        }
        let slug = String(String.UnicodeScalarView(kept))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: "-")
            .lowercased()
        return "\(slug.isEmpty ? "route" : slug).gpx"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
