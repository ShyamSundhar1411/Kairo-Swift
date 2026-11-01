import SwiftUI
import KairoKit

/// The watch's own copy of the design tokens.
///
/// The iOS target has the full system (`KairoTheme` / `KairoComponents`); none of
/// it is compiled into the watch target, so this is the deliberately small
/// equivalent: the palette, a type scale, the nudge-class vocabulary, and the two
/// primitives the wrist actually needs - a pill and a ring.
///
/// watchOS is always dark, so there is no dark/light pair and no trait lookup:
/// literal colours are both correct and simpler.
///
/// The split the palette encodes is the product thesis. Amber is attention being
/// *spent* - it belongs to interruptions. Teal is Kairo staying quiet, and it
/// belongs to the screen the user sees most of the time.
enum Kairo {

    // MARK: - Accents

    static let amber  = rgb(0xFFB65C)
    static let teal   = rgb(0x4FD1C5)
    static let violet = rgb(0x9B8CFF)
    static let coral  = rgb(0xFF7E6B)
    static let leaf   = rgb(0x7BDC8A)
    static let sky    = rgb(0x66B8FF)

    // MARK: - Ink

    static let ink      = rgb(0xF3F6FB)
    static let inkSoft  = rgb(0x9CA9BF)
    static let inkFaint = rgb(0x64718A)

    // MARK: - Full-bleed washes
    //
    // Both go behind the whole screen via `.containerBackground(for: .navigation)`,
    // and the contrast between them is the point: an interruption arrives warm and
    // saturated, silence stays cool and dim.

    /// The background of an interruption, keyed to what interrupted you.
    static func nudgeWash(forNudgeClass c: String) -> LinearGradient {
        let tint = colour(forNudgeClass: c)
        return LinearGradient(stops: [
            .init(color: tint.opacity(0.58), location: 0),
            .init(color: tint.opacity(0.20), location: 0.55),
            // A tinted floor rather than pure black: bottoming out at black puts
            // a visible band across the screen under the buttons.
            .init(color: rgb(0x120C08), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The background of the quiet state.
    static var quietWash: LinearGradient {
        LinearGradient(stops: [
            .init(color: teal.opacity(0.28), location: 0),
            .init(color: sky.opacity(0.12), location: 0.55),
            .init(color: rgb(0x08110F), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    /// The brand's warm sweep, and the only thing the mark's lit segments are
    /// drawn with. Same three stops and same start angle as the phone, so the
    /// mark reads as one logo across both platforms.
    static var sweep: AngularGradient {
        AngularGradient(colors: [amber, coral, amber], center: .center,
                        startAngle: .degrees(-90), endAngle: .degrees(270))
    }

    /// The sweep a ring's filled arc is drawn with. One colour fades into itself;
    /// two sweep from the first to the second.
    static func arc(_ from: Color, _ to: Color? = nil) -> AngularGradient {
        AngularGradient(colors: [to == nil ? from.opacity(0.5) : from, to ?? from],
                        center: .center,
                        startAngle: .degrees(-90), endAngle: .degrees(270))
    }

    // MARK: - Nudge classes
    //
    // Same colours, glyphs and short titles as the phone, so a nudge looks like
    // the same nudge on both wrists and screens. Classes arrive as raw strings
    // over WatchConnectivity and models reach for synonyms, so normalise first.

    static func icon(forNudgeClass c: String) -> String {
        switch NudgeClassVocabulary.normalise(c) ?? "" {
        case "hydration":   "drop.fill"
        case "sedentary":   "figure.stand"
        case "bedtimePrep": "moon.zzz.fill"
        case "mealLog":     "fork.knife"
        case "movement":    "figure.walk"
        default:            "bell.fill"
        }
    }

    static func colour(forNudgeClass c: String) -> Color {
        switch NudgeClassVocabulary.normalise(c) ?? "" {
        case "hydration":   sky
        case "sedentary":   amber
        case "bedtimePrep": violet
        case "mealLog":     leaf
        case "movement":    teal
        default:            amber
        }
    }

    static func title(forNudgeClass c: String) -> String {
        switch NudgeClassVocabulary.normalise(c) ?? "" {
        case "hydration":   "Water"
        case "sedentary":   "Sitting"
        case "bedtimePrep": "Wind down"
        case "mealLog":     "Meal log"
        case "movement":    "Movement"
        default:            c.isEmpty ? "Kairo" : c
        }
    }

    // MARK: - Logged entries
    //
    // A logged entry is the same subject matter as a nudge class, so it reuses
    // the palette above rather than starting a second one: water is water
    // whether Kairo asked for it or the user simply logged it.

    /// The nudge class a logged entry belongs to, so the two vocabularies stay
    /// one. `.interruption` deliberately maps to no class: it is not *about*
    /// hydration or sitting, it is the attention that was spent, so it takes the
    /// default branch above - amber and a bell. Amber is attention being spent,
    /// which is the whole point of the palette, so that default is the right
    /// answer rather than an accident.
    static func nudgeClass(for kind: DayLog.Entry.Kind) -> String {
        switch kind {
        case .water:        "hydration"
        case .meal:         "mealLog"
        case .sleep:        "bedtimePrep"
        case .interruption: ""
        }
    }

    static func icon(for kind: DayLog.Entry.Kind) -> String {
        icon(forNudgeClass: nudgeClass(for: kind))
    }

    static func colour(for kind: DayLog.Entry.Kind) -> Color {
        colour(forNudgeClass: nudgeClass(for: kind))
    }

    // MARK: - Colour plumbing

    private static func rgb(_ v: UInt32) -> Color {
        Color(.sRGB,
              red:   Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue:  Double(v & 0xFF) / 255,
              opacity: 1)
    }
}

// MARK: - Type scale
//
// Rounded everywhere a number or a claim is the point, matching the phone. Sizes
// are the watch's own - a 40mm screen is 162pt wide and nothing here assumes more.

extension Font {
    /// The one number a page is about.
    static let wNumber   = Font.system(size: 30, weight: .semibold, design: .rounded)
    /// The nudge text: the loudest thing on the watch, and the only thing on it.
    static let wBid      = Font.system(size: 21, weight: .semibold, design: .rounded)
    static let wTitle    = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let wButton   = Font.system(size: 13, weight: .semibold, design: .rounded)
    static let wCaption  = Font.system(size: 11, weight: .regular)
    /// The smallest thing worth putting on a wrist: a timestamp under a line, or
    /// a secondary figure in a summary. Anything under this stops being readable
    /// on a 40mm screen, so this is the floor rather than a starting point.
    static let wMicro    = Font.system(size: 9, weight: .regular)
    /// Small, tracked, uppercase - pills and unit labels.
    static let wLabel    = Font.system(size: 10, weight: .semibold, design: .rounded)
}

// MARK: - Pill

/// A glyph and a short word, used to name the thing on screen without spending a
/// headline on it.
struct WatchPill: View {
    let text: String
    var icon: String?
    var tint: Color = Kairo.inkSoft

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
            }
            Text(text.uppercased()).font(.wLabel).tracking(0.8)
        }
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.18)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Ring

/// Hand-drawn rather than a `Gauge`, because the centre has to hold a large
/// rounded numeral and the accessory gauge styles fix their own size.
struct WatchRing<Centre: View>: View {
    let progress: Double
    var tint: Color = Kairo.amber
    /// Optional second stop, so the arc can sweep between two accents.
    var to: Color?
    var size: CGFloat = 88
    var lineWidth: CGFloat = 9
    @ViewBuilder var centre: Centre

    var body: some View {
        let p = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: p)
                .stroke(Kairo.arc(tint, to),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            centre
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: p)
    }
}

// MARK: - The brand mark

/// The motif, restated natively on the watch.
///
/// The phone owns the canonical drawing (`KairoMark`, in the iOS target, which is
/// not on the watch's compile path), so this is the same geometry written out
/// again rather than shared: five segments with the first three lit, 19-degree
/// gaps, a stroke of 9.5% of the diameter with round caps, the warm sweep, and a
/// solid amber dot at 21% of the diameter in the middle. Keep those numbers in
/// step with the phone's and the two platforms stay one brand.
struct WatchSegmentedRing: View {
    var segments: Int = 5
    var filled: Int = 3
    /// Index of the first lit segment, so the lit run can be moved around the
    /// ring - which is all the loader does.
    var firstLit: Int = 0
    /// Stroke weight as a fraction of the diameter, so the proportions hold from
    /// a 20pt mark to a 60pt one.
    var weight: CGFloat = 0.095
    var gapDegrees: Double = 19
    var size: CGFloat = 44
    var filledStyle: AnyShapeStyle = AnyShapeStyle(Kairo.sweep)
    var emptyStyle: AnyShapeStyle = AnyShapeStyle(Color.white.opacity(0.12))
    var glow: Color? = Kairo.amber
    /// Lights the lit segments one after another when the view appears.
    var animatesIn: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        ZStack {
            ForEach(0..<max(segments, 1), id: \.self) { i in
                segment(i)
                    .opacity(animatesIn && !revealed && !reduceMotion ? 0 : 1)
                    .animation(.easeOut(duration: 0.35).delay(Double(i) * 0.05),
                               value: revealed)
            }
        }
        .frame(width: size, height: size)
        .onAppear { revealed = true }
    }

    private func isLit(_ i: Int) -> Bool {
        let n = max(segments, 1)
        let f = min(max(filled, 0), n)
        guard f > 0 else { return false }
        return ((i - firstLit) % n + n) % n < f
    }

    private func segment(_ i: Int) -> some View {
        let span = 1.0 / Double(max(segments, 1))
        // Never let the gap eat the segment on a small ring.
        let gap = min(gapDegrees / 360, span * 0.35)
        let lit = isLit(i)
        return Circle()
            .trim(from: Double(i) * span + gap / 2, to: Double(i + 1) * span - gap / 2)
            .stroke(lit ? filledStyle : emptyStyle,
                    style: StrokeStyle(lineWidth: size * weight, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .shadow(color: lit ? (glow?.opacity(0.45) ?? .clear) : .clear,
                    radius: size * 0.05)
    }
}

/// The logo on its own: the segmented ring with the moment at its centre.
struct WatchMark: View {
    var size: CGFloat = 44
    /// Collapses the mark to one colour, for a state that should not look live -
    /// the link being down, for instance.
    var monochrome: Color?
    var animatesIn: Bool = false

    var body: some View {
        ZStack {
            WatchSegmentedRing(
                size: size,
                filledStyle: monochrome.map { AnyShapeStyle($0) }
                    ?? AnyShapeStyle(Kairo.sweep),
                emptyStyle: AnyShapeStyle((monochrome ?? Color.white).opacity(0.16)),
                glow: monochrome ?? Kairo.amber,
                animatesIn: animatesIn)

            Circle()
                .fill(monochrome ?? Kairo.amber)
                .frame(width: size * 0.21, height: size * 0.21)
                .shadow(color: (monochrome ?? Kairo.amber).opacity(0.6),
                        radius: size * 0.09)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The mark in motion: the same ring, turning, so the lit segments chase around
/// it. Used for the one state that is genuinely still loading - the phone link
/// activating - instead of a stock spinner.
///
/// Reduce Motion stops the turn outright and leaves the mark standing still; the
/// copy beside it, not the animation, is what says the watch is still connecting.
struct WatchMarkLoader: View {
    var size: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            WatchSegmentedRing(size: size)
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(reduceMotion
                           ? nil
                           : .linear(duration: 2.4).repeatForever(autoreverses: false),
                           value: turning)

            Circle()
                .fill(Kairo.amber)
                .frame(width: size * 0.21, height: size * 0.21)
                .shadow(color: Kairo.amber.opacity(0.6), radius: size * 0.09)
        }
        .frame(width: size, height: size)
        .onAppear { turning = true }
        .accessibilityHidden(true)
    }
}
