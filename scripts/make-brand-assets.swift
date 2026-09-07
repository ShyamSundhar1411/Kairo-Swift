import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders every raster brand asset from one description of the letterform: a K,
// both arms at equal weight leaving one junction, optically shifted right
// because a K is left-heavy. The identical fractions are drawn in SwiftUI by
// `KairoLetter` in apps/ios/KairoApp/Design/KairoLogo.swift — change one and you
// must change the other.
//
// The segmented ring is NOT here. It is the attention dial, not the logo, and it
// only ever exists as SwiftUI.
//
// Regenerate everything — app icons in all three iOS appearance variants for
// both targets, the launch mark at 1x/2x/3x in both appearances, and the
// asset-catalog metadata:
//
//     swift scripts/make-brand-assets.swift
//
// Idempotent: it overwrites in place and writes its own Contents.json files.

let cs = CGColorSpaceCreateDeviceRGB()

func colour(_ rgb: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        CGFloat(Double((rgb >> 16) & 0xFF) / 255),
        CGFloat(Double((rgb >> 8) & 0xFF) / 255),
        CGFloat(Double(rgb & 0xFF) / 255),
        CGFloat(a)])!
}

/// Draws the K filling `px` square. `glow` is for the dark treatments only; on
/// the flat amber field a shadow reads as a printing fault.
func drawLetter(into ctx: CGContext, px: Double, ink: CGColor, glow: UInt32? = nil) {
    let shift = 0.014
    let stemX = (0.330 + shift) * px
    let armX = (0.726 + shift) * px
    // CoreGraphics is y-up; these fractions are quoted from the top, as in the
    // SwiftUI version, so they are flipped here.
    let fromTop = { (u: Double) in (1 - u) * px }
    let junction = CGPoint(x: stemX, y: fromTop(0.505))

    ctx.setLineCap(.round)
    ctx.setStrokeColor(ink)
    if let g = glow {
        ctx.setShadow(offset: .zero, blur: CGFloat(px * 0.05), color: colour(g, 0.45))
    } else {
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    ctx.setLineWidth(CGFloat(px * 0.128))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: stemX, y: fromTop(0.170)))
    ctx.addLine(to: CGPoint(x: stemX, y: fromTop(0.830)))
    ctx.strokePath()

    ctx.setLineWidth(CGFloat(px * 0.118))
    for end in [CGPoint(x: armX, y: fromTop(0.180)), CGPoint(x: armX, y: fromTop(0.820))] {
        ctx.beginPath(); ctx.move(to: junction); ctx.addLine(to: end); ctx.strokePath()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
}

func newContext(_ px: Double) -> CGContext {
    guard let ctx = CGContext(data: nil, width: Int(px), height: Int(px),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("no context")
    }
    return ctx
}

func write(_ ctx: CGContext, to path: String) {
    guard let image = ctx.makeImage() else { fatalError("no image") }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("no destination for \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

func writeJSON(_ text: String, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try! text.data(using: .utf8)!.write(to: url)
    print("wrote \(path)")
}

// MARK: - The app icon
//
// No rounded corners and no transparency: iOS applies its own mask, and a
// pre-rounded icon gets masked twice. Three appearance variants — the warm field
// for light, the letter alone on ink for dark so it sits back on a dark home
// screen, and greyscale for tinted, where the system supplies tint and ground.

enum Appearance: String, CaseIterable {
    case light, dark, tinted
}

func renderIcon(_ appearance: Appearance, to path: String) {
    let px = 1024.0
    let ctx = newContext(px)
    let full = CGRect(x: 0, y: 0, width: px, height: px)

    switch appearance {
    case .light:
        let field = CGGradient(colorsSpace: cs,
                               colors: [colour(0xFFCB79), colour(0xEF8534)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(field, start: CGPoint(x: 0, y: px),
                               end: CGPoint(x: px, y: 0), options: [])
        // A light source at the top left, so the field is lit rather than flat.
        let lift = CGGradient(colorsSpace: cs,
                              colors: [colour(0xFFFFFF, 0.26), colour(0xFFFFFF, 0)] as CFArray,
                              locations: [0, 1])!
        let p = CGPoint(x: px * 0.20, y: px * 0.86)
        ctx.drawRadialGradient(lift, startCenter: p, startRadius: 0, endCenter: p,
                               endRadius: CGFloat(px * 0.78), options: [])
        drawLetter(into: ctx, px: px, ink: colour(0x0B1017))

    case .dark:
        // Deliberately still the warm field, only deeper. Inverting this to an
        // ink tile with an amber letter was tried and rejected: on a dark home
        // screen it disappeared next to every other black icon, which defeats
        // the one job an icon has. Dark mode gets a quieter version of the same
        // icon, not a different one.
        let field = CGGradient(colorsSpace: cs,
                               colors: [colour(0xE0A557), colour(0xB9631F)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(field, start: CGPoint(x: 0, y: px),
                               end: CGPoint(x: px, y: 0), options: [])
        let lift = CGGradient(colorsSpace: cs,
                              colors: [colour(0xFFFFFF, 0.16), colour(0xFFFFFF, 0)] as CFArray,
                              locations: [0, 1])!
        let p = CGPoint(x: px * 0.20, y: px * 0.86)
        ctx.drawRadialGradient(lift, startCenter: p, startRadius: 0, endCenter: p,
                               endRadius: CGFloat(px * 0.78), options: [])
        drawLetter(into: ctx, px: px, ink: colour(0x0B1017))

    case .tinted:
        ctx.setFillColor(colour(0x000000))
        ctx.fill(full)
        drawLetter(into: ctx, px: px, ink: colour(0xFFFFFF))
    }
    write(ctx, to: path)
}

// MARK: - The launch mark
//
// Transparent, amber, and the same box as `KairoLetter(size: 160)` in the
// splash, so the static launch screen and the first SwiftUI frame are the same
// picture in the same place.

func renderLaunchMark(pt: Double, scale: Int, ink: UInt32, to path: String) {
    let px = pt * Double(scale)
    let ctx = newContext(px)
    drawLetter(into: ctx, px: px, ink: colour(ink))
    write(ctx, to: path)
}

// MARK: - Run

let root = FileManager.default.currentDirectoryPath
let iosAssets = "\(root)/apps/ios/KairoApp/Resources/Assets.xcassets"
let watchAssets = "\(root)/apps/watch/KairoWatch/Assets.xcassets"

guard FileManager.default.fileExists(atPath: iosAssets) else {
    fatalError("run this from the repository root: swift scripts/make-brand-assets.swift")
}

// iOS gets all three appearances; watchOS icons have no appearance variants and
// are masked to a circle, which the letterform clears comfortably.
let iosSet = "\(iosAssets)/AppIcon.appiconset"
var iconEntries: [String] = []
for appearance in Appearance.allCases {
    let file = "icon-\(appearance.rawValue).png"
    renderIcon(appearance, to: "\(iosSet)/\(file)")
    let variant = appearance == .light ? "" : """
    ,
          "appearances" : [
            { "appearance" : "luminosity", "value" : "\(appearance.rawValue)" }
          ]
    """
    iconEntries.append("""
        {
          "filename" : "\(file)",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"\(variant)
        }
    """)
}
writeJSON("""
{
  "images" : [
\(iconEntries.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", to: "\(iosSet)/Contents.json")

let watchSet = "\(watchAssets)/AppIcon.appiconset"
renderIcon(.light, to: "\(watchSet)/icon-1024.png")
writeJSON("""
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "watchos",
      "size" : "1024x1024"
    }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", to: "\(watchSet)/Contents.json")

// Launch mark — 160pt, both appearances, three scales.
let launchPT = 160.0
let launchSet = "\(iosAssets)/LaunchMark.imageset"
var launchImages: [String] = []
for (name, ink, dark) in [("mark-light", UInt32(0xC4761A), false),
                          ("mark-dark", UInt32(0xFFB65C), true)] {
    for scale in 1...3 {
        let suffix = scale == 1 ? "" : "@\(scale)x"
        let file = "\(name)\(suffix).png"
        renderLaunchMark(pt: launchPT, scale: scale, ink: ink, to: "\(launchSet)/\(file)")
        let appearances = dark ? """
        ,
          "appearances" : [
            { "appearance" : "luminosity", "value" : "dark" }
          ]
        """ : ""
        launchImages.append("""
            {
              "filename" : "\(file)",
              "idiom" : "universal",
              "scale" : "\(scale)x"\(appearances)
            }
        """)
    }
}
writeJSON("""
{
  "images" : [
\(launchImages.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "original" }
}
""", to: "\(launchSet)/Contents.json")

// Launch background — the same two values `Kairo.canvas` resolves to, so the
// handoff from the static launch screen to the app is invisible.
func colourset(_ rgb: UInt32, dark: Bool) -> String {
    let f = { (shift: UInt32) in String(format: "0x%02X", (rgb >> shift) & 0xFF) }
    let appearances = dark ? """
    ,
      "appearances" : [
        { "appearance" : "luminosity", "value" : "dark" }
      ]
    """ : ""
    return """
        {
          "color" : {
            "color-space" : "srgb",
            "components" : {
              "alpha" : "1.000",
              "blue" : "\(f(0))",
              "green" : "\(f(8))",
              "red" : "\(f(16))"
            }
          },
          "idiom" : "universal"\(appearances)
        }
    """
}
writeJSON("""
{
  "colors" : [
\(colourset(0xF2F4F8, dark: false)),
\(colourset(0x070A0F, dark: true))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""", to: "\(iosAssets)/LaunchBackground.colorset/Contents.json")

print("\nbrand assets regenerated")
