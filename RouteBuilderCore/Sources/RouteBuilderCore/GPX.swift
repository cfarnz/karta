import Foundation

/// GPX 1.1 serialisation.
///
/// Track points carry elevation so COROS and Gaia show a real profile rather
/// than a flat line.
public enum GPX {
    public static func document(for coordinates: [Coordinate], name: String = "Route") -> String {
        let points = coordinates.map { coordinate -> String in
            let lat = String(format: "%.6f", coordinate.latitude)
            let lon = String(format: "%.6f", coordinate.longitude)
            let elevation = coordinate.elevation.map {
                "<ele>\(String(format: "%.1f", $0))</ele>"
            } ?? ""
            return #"      <trkpt lat="\#(lat)" lon="\#(lon)">\#(elevation)</trkpt>"#
        }.joined(separator: "\n")

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
