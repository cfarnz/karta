import SwiftUI

/// Clay's Field Instrument system, ported from `tokens.css`.
///
/// The character is a well-made field instrument: dark, warm, quiet, dense
/// with real numbers, honest about where its data came from. Not a SaaS
/// dashboard and not a consumer app.
///
/// The chrome is dark over a deliberately light topo basemap, which is how
/// every serious mapping tool handles it: the panels recede and the terrain
/// stays the brightest thing on screen. Colours are explicit tokens rather
/// than system semantic colours, so the app looks the same whatever the
/// device is set to.
enum Field {

    // ---------- neutrals: warm, not blue-grey ----------

    static let bg0 = Color(hex: 0x131518)   // page
    static let bg1 = Color(hex: 0x1A1D22)   // panel, card, sheet
    static let bg2 = Color(hex: 0x22262C)   // input, raised control, hover
    static let line = Color(hex: 0x31353F)  // hairline borders

    static let text = Color(hex: 0xE8E6E1)      // warm off-white, never pure white
    static let textDim = Color(hex: 0x9A978F)   // labels, units, secondary
    static let textFaint = Color(hex: 0x6D6A64) // placeholders, disabled

    // ---------- one accent, everything else is semantic ----------

    static let accent = Color(hex: 0xE07A3F)
    static let accentHover = Color(hex: 0xEF8B4F)
    /// 15% tint, for selected fills. A selected control gets a fill, not just
    /// a border — a border alone is indistinguishable from hover.
    static let accentFill = Color(hex: 0xE07A3F, opacity: 0.15)
    static let onAccent = Color(hex: 0x14161A)

    // ---------- semantic: meaning only, never decoration ----------

    static let ok = Color(hex: 0x3FA060)
    static let warn = Color(hex: 0xD9A441)
    static let danger = Color(hex: 0xC94141)
    static let info = Color(hex: 0x4F9DE0)

    /// Lifted variants. The base colours are tuned for borders and fills and
    /// read too dark as type on a dark ground.
    static let okText = Color(hex: 0x7FD89F)
    static let warnText = Color(hex: 0xEEC97F)
    static let dangerText = Color(hex: 0xEE8F8F)
    static let infoText = Color(hex: 0x8FC4F0)
    static let accentText = Color(hex: 0xF0A37A)

    // ---------- type ----------
    //
    // Tracking is size-specific: large text tightens, small text opens up. A
    // single letter-spacing value would be wrong somewhere.

    enum Size {
        static let xs: CGFloat = 11    // units, meta, legends
        static let sm: CGFloat = 13    // labels, controls
        static let base: CGFloat = 15  // body
        static let lg: CGFloat = 18    // section heads
        static let xl: CGFloat = 24    // page title
        static let xxl: CGFloat = 32   // hero number
    }

    enum Track {
        static let xs: CGFloat = 0.11
        static let sm: CGFloat = 0
        static let base: CGFloat = 0
        static let lg: CGFloat = -0.18
        static let xl: CGFloat = -0.36
        static let xxl: CGFloat = -0.70
        /// Small caps labels. The one place tracking opens up hard.
        static let label: CGFloat = 0.8
    }

    // ---------- space: 4pt base, no in-between values ----------

    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x6: CGFloat = 24
        static let x8: CGFloat = 32
    }

    // ---------- radius ----------

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        static let surface: CGFloat = 12
    }

    // ---------- motion ----------
    //
    // Custom curves: the built-ins are too weak to read as intentional.
    // Everything stays under 300ms.

    static let easeOut = UnitCurve.bezier(
        startControlPoint: .init(x: 0.23, y: 1), endControlPoint: .init(x: 0.32, y: 1))

    static func out(_ duration: TimeInterval) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
    /// Sheets and drawers.
    static func drawer(_ duration: TimeInterval = 0.28) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }

    enum Duration {
        static let press: TimeInterval = 0.14
        static let tip: TimeInterval = 0.16
        static let menu: TimeInterval = 0.20
        static let panel: TimeInterval = 0.28
    }
}

// ---------- colour helper ----------

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

// ==========================================================================
// Components
// ==========================================================================

/// A number and its unit as one object, never two.
///
/// Mono and tabular so digits do not reflow as values change. A distance
/// readout that shifts width while you drag is the fastest way to look
/// amateur, and this app has three of them updating under a finger.
struct Readout: View {
    let value: String
    var unit: String?
    var size: CGFloat = Field.Size.xl
    var weight: Font.Weight = .medium
    var tint: Color = Field.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: weight, design: .monospaced))
                .monospacedDigit()
                .kerning(-0.01 * size)
                .foregroundStyle(tint)
            if let unit {
                Text(unit)
                    .font(.system(size: size * 0.55, design: .monospaced))
                    .foregroundStyle(Field.textDim)
            }
        }
    }
}

/// Small caps label above a value or control.
struct FieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(Field.Track.label)
            .foregroundStyle(Field.textDim)
    }
}

/// Where a number came from, how old it is, and whether it is any good.
///
/// Provenance is a first-class element here, not a debug affordance: a number
/// with no origin is a number you cannot act on in the field.
enum SourceState {
    case live, cached, stale, error

    init(isStale: Bool, fromCache: Bool, failed: Bool = false) {
        if failed { self = .error }
        else if isStale { self = .stale }
        else if fromCache { self = .cached }
        else { self = .live }
    }

    var color: Color {
        switch self {
        case .live: Field.ok
        case .cached: Field.info
        case .stale: Field.warn
        case .error: Field.danger
        }
    }

    var label: String {
        switch self {
        case .live: "live"
        case .cached: "cached"
        case .stale: "stale"
        case .error: "failed"
        }
    }
}

// ==========================================================================
// Modifiers
// ==========================================================================

extension View {
    /// Panel, card or sheet surface.
    func fieldSurface(_ radius: CGFloat = Field.Radius.card) -> some View {
        self
            .background(Field.bg1, in: .rect(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Field.line, lineWidth: 1))
    }

    /// The floating chrome that sits over the map. Slightly translucent so
    /// the terrain underneath stays readable, which a solid panel would hide.
    func fieldOverlay(_ radius: CGFloat = Field.Radius.surface) -> some View {
        self
            .background(Field.bg1.opacity(0.82), in: .rect(cornerRadius: radius))
            .background(.ultraThinMaterial, in: .rect(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Field.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }

    /// Provenance stripe: a 3pt coloured left border.
    func sourceStripe(_ state: SourceState) -> some View {
        self
            .padding(.leading, Field.Space.x2)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(state.color)
                    .frame(width: 3)
            }
    }
}

// ==========================================================================
// Button styles
// ==========================================================================

/// Press feedback on pointer-down, not on release. Waiting for the click
/// feels dead.
struct FieldButtonStyle: ButtonStyle {
    var isActive = false
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Field.Size.sm, weight: isProminent ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, Field.Space.x3)
            .padding(.vertical, Field.Space.x2)
            .background(background, in: .rect(cornerRadius: Field.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Field.Radius.control)
                    .stroke(border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Field.out(Field.Duration.press), value: configuration.isPressed)
    }

    private var foreground: Color {
        if isProminent { return Field.onAccent }
        return isActive ? Field.accentText : Field.text
    }

    private var background: Color {
        if isProminent { return Field.accent }
        // Selected is a fill, not just a border.
        return isActive ? Field.accentFill : Field.bg2
    }

    private var border: Color {
        isProminent || isActive ? Field.accent : Field.line
    }
}

extension ButtonStyle where Self == FieldButtonStyle {
    static var field: FieldButtonStyle { FieldButtonStyle() }
    static func field(active: Bool) -> FieldButtonStyle {
        FieldButtonStyle(isActive: active)
    }
    static var fieldProminent: FieldButtonStyle {
        FieldButtonStyle(isProminent: true)
    }
}
