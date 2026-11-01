import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Sample dishes for the simulated viewfinder.
//
// These are ILLUSTRATIONS, not photographs. They exist so the capture flow can
// be demonstrated on a simulator, which has no camera, and so the three
// branches of the MealEntry machine each have something to point a lens at.
// They are drawn rather than downloaded on purpose: a stock photograph would
// put an asset of unknown licence in the repository, and a photorealistic fake
// would invite exactly the "is this a real reading?" confusion the app is built
// to avoid.
//
// Drop real photographs over the top if you have them - same names, same folder:
//
//     swift scripts/make-sample-meals.swift

let cs = CGColorSpaceCreateDeviceRGB()
func c(_ rgb: UInt32, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [
        CGFloat(Double((rgb >> 16) & 0xFF)/255), CGFloat(Double((rgb >> 8) & 0xFF)/255),
        CGFloat(Double(rgb & 0xFF)/255), CGFloat(a)])!
}

let W = 900.0, H = 1200.0

func newContext() -> CGContext {
    CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ ctx: CGContext, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

/// Table, vignette, and the plate the food sits on.
func ground(_ ctx: CGContext, table: UInt32, plate: UInt32, plateRadius: Double = 0.34) {
    let g = CGGradient(colorsSpace: cs, colors: [c(table), c(table &- 0x0A0A0A)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

    // A soft window light from the top left, which is what makes it read as a
    // photograph of a surface rather than a flat swatch.
    let light = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.13), c(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    let lp = CGPoint(x: W*0.22, y: H*0.88)
    ctx.drawRadialGradient(light, startCenter: lp, startRadius: 0, endCenter: lp,
                           endRadius: CGFloat(W*0.75), options: [])

    let mid = CGPoint(x: W/2, y: H/2)
    let r = W * plateRadius
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0x000000, 0.45))
    ctx.setFillColor(c(plate))
    ctx.fillEllipse(in: CGRect(x: mid.x - r, y: mid.y - r*0.86, width: r*2, height: r*1.72))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Rim.
    ctx.setLineWidth(CGFloat(W * 0.006))
    ctx.setStrokeColor(c(0x000000, 0.10))
    ctx.strokeEllipse(in: CGRect(x: mid.x - r*0.86, y: mid.y - r*0.74,
                                 width: r*1.72, height: r*1.48))
}

func blob(_ ctx: CGContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
          _ col: CGColor, rotate: Double = 0) {
    ctx.saveGState()
    ctx.translateBy(x: CGFloat(x), y: CGFloat(y))
    ctx.rotate(by: CGFloat(rotate * .pi/180))
    ctx.setFillColor(col)
    let path = CGPath(roundedRect: CGRect(x: -w/2, y: -h/2, width: w, height: h),
                      cornerWidth: CGFloat(min(w, h)/2), cornerHeight: CGFloat(min(w, h)/2),
                      transform: nil)
    ctx.addPath(path); ctx.fillPath()
    ctx.restoreGState()
}

// MARK: - 1. Grilled salmon and rice - the confident path

func salmon() -> CGContext {
    let ctx = newContext()
    ground(ctx, table: 0x2B2622, plate: 0xF1EDE6)

    // Rice.
    for (dx, dy, r) in [(-150.0, -30.0, 96.0), (-196.0, 24.0, 74.0), (-104.0, 34.0, 70.0)] {
        ctx.setFillColor(c(0xFBF8F1))
        ctx.fillEllipse(in: CGRect(x: W/2 + dx - r, y: H/2 + dy - r*0.7,
                                   width: r*2, height: r*1.4))
    }
    for i in 0..<70 {
        let a = Double(i) * 1.37
        ctx.setFillColor(c(0xE8E1D2, 0.8))
        blob(ctx, W/2 - 150 + cos(a)*Double(i%9)*15, H/2 + cos(a*2)*Double(i%7)*13,
             17, 8, c(0xE8E1D2, 0.75), rotate: a*30)
    }

    // Salmon fillet, with its flesh lines.
    blob(ctx, W/2 + 110, H/2 + 6, 300, 176, c(0xD9704A), rotate: -8)
    for i in 0..<5 {
        blob(ctx, W/2 + 110 + Double(i-2)*8, H/2 + 6 + Double(i-2)*30,
             276 - Double(abs(i-2))*36, 12, c(0xF0A882, 0.85), rotate: -8)
    }
    // Charred edge.
    blob(ctx, W/2 + 110, H/2 - 78, 292, 20, c(0x8A3F27, 0.75), rotate: -8)

    // Asparagus.
    for i in 0..<3 {
        blob(ctx, W/2 - 40 + Double(i)*20, H/2 - 150 + Double(i)*6, 250, 26,
             c(0x5C8A3A), rotate: -6 + Double(i)*3)
    }
    // Lemon.
    ctx.setFillColor(c(0xF2D24B))
    ctx.fillEllipse(in: CGRect(x: W/2 + 210, y: H/2 + 120, width: 108, height: 76))
    return ctx
}

// MARK: - 2. Stir-fried noodles - the ambiguous portion

func noodles() -> CGContext {
    let ctx = newContext()
    ground(ctx, table: 0x241F1C, plate: 0x2E3138, plateRadius: 0.31)

    // Noodles: many overlapping arcs, deliberately hard to portion by eye.
    ctx.setLineCap(.round)
    for i in 0..<46 {
        let a = Double(i) * 0.71
        let r = 60.0 + Double(i % 11) * 16
        ctx.setLineWidth(CGFloat(15 - Double(i % 3)))
        ctx.setStrokeColor(c(i % 4 == 0 ? 0xE8B65C : 0xD9A04E, 0.95))
        ctx.beginPath()
        ctx.addArc(center: CGPoint(x: W/2 + cos(a)*70, y: H/2 + sin(a)*46),
                   radius: CGFloat(r), startAngle: CGFloat(a), endAngle: CGFloat(a + 2.4),
                   clockwise: false)
        ctx.strokePath()
    }
    // Vegetables and protein scattered through it.
    for (dx, dy, w, h, col) in [(-120.0, 40.0, 72.0, 30.0, UInt32(0x4F7F35)),
                                (90.0, -60.0, 64.0, 28.0, UInt32(0x4F7F35)),
                                (10.0, 70.0, 58.0, 34.0, UInt32(0xB5563A)),
                                (-60.0, -90.0, 54.0, 32.0, UInt32(0xB5563A)),
                                (150.0, 30.0, 46.0, 26.0, UInt32(0xE4E0D2))] {
        blob(ctx, W/2 + dx, H/2 + dy, w, h, c(col), rotate: dx)
    }
    return ctx
}

// MARK: - 3. A dish Kairo has never seen - the ungrounded path

func unfamiliar() -> CGContext {
    let ctx = newContext()
    ground(ctx, table: 0x1F1D22, plate: 0x3A3339, plateRadius: 0.30)

    // A stew whose components genuinely cannot be told apart, which is the
    // point: there is nothing here a reference entry would match.
    let mid = CGPoint(x: W/2, y: H/2)
    ctx.setFillColor(c(0x7A4A2A))
    ctx.fillEllipse(in: CGRect(x: mid.x - 250, y: mid.y - 190, width: 500, height: 380))
    for i in 0..<26 {
        let a = Double(i) * 1.9
        let d = 40.0 + Double(i % 8) * 22
        blob(ctx, mid.x + cos(a)*d, mid.y + sin(a)*d*0.78,
             52 + Double(i % 5)*16, 40 + Double(i % 4)*12,
             c([0x8F5C33, 0x6B3F24, 0xA7743F, 0x5A3520][i % 4], 0.95), rotate: a*40)
    }
    // A sheen, so it reads as wet rather than as a texture swatch.
    let sheen = CGGradient(colorsSpace: cs, colors: [c(0xFFFFFF, 0.16), c(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    let sp = CGPoint(x: mid.x - 90, y: mid.y + 90)
    ctx.drawRadialGradient(sheen, startCenter: sp, startRadius: 0, endCenter: sp,
                           endRadius: 240, options: [])
    // A garnish that identifies nothing.
    for i in 0..<7 {
        blob(ctx, mid.x - 60 + Double(i)*26, mid.y + 120 + Double(i % 3)*14,
             40, 12, c(0x6F8F45), rotate: Double(i)*24)
    }
    return ctx
}

// MARK: - Run

let root = FileManager.default.currentDirectoryPath
let assets = "\(root)/apps/ios/KairoApp/Resources/Assets.xcassets"
guard FileManager.default.fileExists(atPath: assets) else {
    fatalError("run this from the repository root: swift scripts/make-sample-meals.swift")
}

for (name, make) in [("meal-salmon", salmon), ("meal-noodles", noodles),
                     ("meal-unfamiliar", unfamiliar)] {
    let set = "\(assets)/\(name).imageset"
    write(make(), to: "\(set)/\(name).png")
    // Single-scale: one PNG serves every device, which is fine for a viewfinder
    // stand-in and keeps three files in the repo instead of nine.
    try! """
    {
      "images" : [
        {
          "filename" : "\(name).png",
          "idiom" : "universal"
        }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """.data(using: .utf8)!.write(to: URL(fileURLWithPath: "\(set)/Contents.json"))
    print("wrote \(set)/Contents.json")
}
print("\nsample meals regenerated")
