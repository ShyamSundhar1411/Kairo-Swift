import SwiftUI
import UIKit
import KairoKit

/// The design tokens, in one place.
///
/// No feature view names a raw colour, a corner radius or a point size — they all
/// resolve through here, so the whole app restyles from this file. Colours are
/// declared as dark/light pairs and resolved by the trait environment, which is
/// why every screen works in both appearances without a second code path.
enum Kairo {

    // MARK: - Canvas

    static let canvas     = pair(dark: 0x070A0F, light: 0xF2F4F8)
    static let canvasLift = pair(dark: 0x0D131C, light: 0xFFFFFF)
    /// Card body. Sits over the material so the canvas glow shows through.
    static let cardTint   = pair(dark: 0x111823, light: 0xFFFFFF)
    static let hairline   = pair(dark: 0xFFFFFF, light: 0x0B1220)

    // MARK: - Ink

    static let ink      = pair(dark: 0xF3F6FB, light: 0x0C111C)
    static let inkSoft  = pair(dark: 0x9CA9BF, light: 0x5B6478)
    static let inkFaint = pair(dark: 0x64718A, light: 0x8D96A8)

    // MARK: - Accents
    //
    // Amber is attention being *spent*; teal is Kairo staying quiet. That split
    // is the product thesis, so it is the first thing the palette encodes.

    static let amber  = pair(dark: 0xFFB65C, light: 0xC4761A)
    static let teal   = pair(dark: 0x4FD1C5, light: 0x0C8C7F)
    static let violet = pair(dark: 0x9B8CFF, light: 0x6249C9)
    static let coral  = pair(dark: 0xFF7E6B, light: 0xCE3A22)
    static let leaf   = pair(dark: 0x7BDC8A, light: 0x1F8F42)
    static let sky    = pair(dark: 0x66B8FF, light: 0x1667C4)

    // MARK: - Gradients

    static var warm: LinearGradient {
        LinearGradient(colors: [amber, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var cool: LinearGradient {
        LinearGradient(colors: [teal, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var deep: LinearGradient {
        LinearGradient(colors: [violet, sky], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Sweeps warm around a full turn. Every segment of the attention dial draws
    /// from the same sweep, so the ring reads as one thing filling up.
    static var sweep: AngularGradient {
        AngularGradient(colors: [amber, coral, amber], center: .center,
                        startAngle: .degrees(-90), endAngle: .degrees(270))
    }
    static func fade(_ c: Color) -> LinearGradient {
        LinearGradient(colors: [c, c.opacity(0.45)], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: - Metrics

    enum Radius {
        static let card: CGFloat = 24
        static let inner: CGFloat = 16
        static let chip: CGFloat = 10
    }

    enum Space {
        static let gutter: CGFloat = 18
        static let stack: CGFloat = 16
        static let tight: CGFloat = 8
    }

    // MARK: - Agent identity
    //
    // Five roles that visibly disagree need to be visibly distinct. One colour
    // and one short name per role, used everywhere a role is named.

    static func colour(forAgent raw: String) -> Color {
        switch AgentID(rawValue: raw) {
        case .coach:     amber
        case .nutrition: leaf
        case .lifestyle: teal
        case .memory:    violet
        case .steward:   coral
        case nil:        inkSoft
        }
    }

    static func shortName(forAgent raw: String) -> String {
        switch AgentID(rawValue: raw) {
        case .coach:     "Coach"
        case .nutrition: "Nutrition"
        case .lifestyle: "Lifestyle"
        case .memory:    "Memory"
        case .steward:   "Steward"
        case nil:        raw
        }
    }

    static func icon(forAgent raw: String) -> String {
        switch AgentID(rawValue: raw) {
        case .coach:     "figure.walk.motion"
        case .nutrition: "leaf"
        case .lifestyle: "waveform.path.ecg"
        case .memory:    "book.closed"
        case .steward:   "shield.lefthalf.filled"
        case nil:        "person"
        }
    }

    // MARK: - Coverage domains

    static func colour(for domain: CoverageDomain) -> Color {
        switch domain {
        case .meals:     leaf
        case .sleep:     violet
        case .movement:  amber
        case .hydration: sky
        }
    }

    static func icon(for domain: CoverageDomain) -> String {
        switch domain {
        case .meals:     "fork.knife"
        case .sleep:     "moon.stars"
        case .movement:  "figure.walk"
        case .hydration: "drop"
        }
    }

    // MARK: - Nudge classes

    static func icon(forNudgeClass c: String) -> String {
        switch c {
        case "hydration":   "drop.fill"
        case "sedentary":   "figure.stand"
        case "bedtimePrep": "moon.zzz.fill"
        case "mealLog":     "fork.knife"
        case "movement":    "figure.walk"
        default:            "bell.fill"
        }
    }

    static func colour(forNudgeClass c: String) -> Color {
        switch c {
        case "hydration":   sky
        case "sedentary":   amber
        case "bedtimePrep": violet
        case "mealLog":     leaf
        case "movement":    teal
        default:            inkSoft
        }
    }

    static func title(forNudgeClass c: String) -> String {
        switch c {
        case "hydration":   "Water"
        case "sedentary":   "Sitting"
        case "bedtimePrep": "Wind down"
        case "mealLog":     "Meal log"
        case "movement":    "Movement"
        default:            c
        }
    }

    // MARK: - Colour plumbing

    private static func pair(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red:   Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue:  Double(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Type scale

extension Font {
    /// The one number a screen is about.
    static let kairoDisplay  = Font.system(size: 52, weight: .semibold, design: .rounded)
    static let kairoNumber   = Font.system(size: 30, weight: .semibold, design: .rounded)
    static let kairoTitle    = Font.system(size: 26, weight: .bold, design: .rounded)
    static let kairoHeadline = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let kairoBody     = Font.system(size: 16, weight: .regular)
    static let kairoCaption  = Font.system(size: 13, weight: .regular)
    /// Small, tracked, uppercase — section labels and pills.
    static let kairoLabel    = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let kairoMono     = Font.system(size: 12, weight: .medium, design: .monospaced)
}

// MARK: - Canvas

/// The app background: a near-black field with a warm glow where attention is
/// spent and a cool one where it is not. Static, cheap, and drawn once per screen.
struct KairoCanvas: View {
    var body: some View {
        Kairo.canvas
            .overlay(alignment: .topTrailing) { glow(Kairo.amber, 0.22).offset(x: 90, y: -120) }
            .overlay(alignment: .topLeading)  { glow(Kairo.violet, 0.16).offset(x: -110, y: -60) }
            .overlay(alignment: .bottomLeading) { glow(Kairo.teal, 0.14).offset(x: -80, y: 120) }
            .ignoresSafeArea()
    }

    private func glow(_ c: Color, _ opacity: Double) -> some View {
        Circle()
            .fill(RadialGradient(colors: [c.opacity(opacity), .clear],
                                 center: .center, startRadius: 0, endRadius: 190))
            .frame(width: 380, height: 380)
            .blur(radius: 40)
            .allowsHitTesting(false)
    }
}
