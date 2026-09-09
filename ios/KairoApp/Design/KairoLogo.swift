import SwiftUI

// The brand mark, and the one implementation of the motif everything else is
// drawn from.
//
// Kairo's mark IS its thesis: a day's interruption budget as a ring of discrete
// segments, part of it spent, and the opportune moment at the centre. The app
// icon, the launch screen, the loaders and the attention dial on Today are all
// the same shape at different sizes — which is why the geometry lives in one
// place instead of being redrawn per use.

// MARK: - The motif

/// A ring divided into `segments`, the first `filled` of them lit.
///
/// Sizes to whatever it is given, so the mark, the loader and the dial differ
/// only in their frame.
struct SegmentedRing: View {
    var segments: Int = 5
    var filled: Int = 3
    /// Stroke weight as a fraction of the diameter, so the ring keeps its
    /// proportions from 16pt to 1024pt.
    var weight: CGFloat = 0.095
    var gapDegrees: Double = 19
    var filledStyle: AnyShapeStyle = AnyShapeStyle(Kairo.sweep)
    var emptyStyle: AnyShapeStyle = AnyShapeStyle(Kairo.hairline.opacity(0.12))
    var glow: Color? = Kairo.amber
    /// Lights the lit segments one after another when the view appears.
    var animatesIn: Bool = false
    /// Rotates the whole ring, which is what turns the mark into a loader.
    var rotation: Angle = .zero

    @State private var revealed = false

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(0..<max(segments, 1), id: \.self) { i in
                    segment(i, diameter: d)
                        .opacity(animatesIn && !revealed ? 0 : 1)
                        .animation(.easeOut(duration: 0.35).delay(Double(i) * 0.05),
                                   value: revealed)
                }
            }
            .frame(width: d, height: d)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .rotationEffect(rotation)
        .onAppear { revealed = true }
    }

    private func segment(_ i: Int, diameter d: CGFloat) -> some View {
        let span = 1.0 / Double(max(segments, 1))
        let gap = min(gapDegrees / 360, span * 0.35)
        let lit = i < filled
        return Circle()
            .trim(from: Double(i) * span + gap / 2, to: Double(i + 1) * span - gap / 2)
            .stroke(lit ? filledStyle : emptyStyle,
                    style: StrokeStyle(lineWidth: d * weight, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .shadow(color: lit ? (glow?.opacity(0.45) ?? .clear) : .clear, radius: d * 0.05)
    }
}

// MARK: - The letterform

/// The identity mark: a K, both arms at equal weight leaving one junction.
///
/// The app icon and the launch screen are this shape. It is drawn rather than
/// typeset so it matches the generated PNGs exactly at any size — the same
/// fractions appear in scripts/make-brand-assets.swift, and changing one means
/// changing both.
///
/// An earlier version lightened the upper arm to mean "the time that simply
/// passes". It destroyed the letter — with one arm faded the shape reads as a
/// lowercase k — so the idea moved to `KairoMark`, where a ring of segments can
/// carry it without anything having to stay legible at 29pt.
struct KairoLetter: View {
    var size: CGFloat = 112
    var colour: Color = Kairo.amber
    var glow = true

    /// Optical shift: a K is left-heavy, so a mathematically centred one looks
    /// wrong in its box.
    private let shift: CGFloat = 0.014

    var body: some View {
        let s = size
        let stemX = (0.330 + shift) * s
        let armX = (0.726 + shift) * s
        let junction = CGPoint(x: stemX, y: 0.505 * s)

        ZStack {
            Path { p in
                p.move(to: CGPoint(x: stemX, y: 0.170 * s))
                p.addLine(to: CGPoint(x: stemX, y: 0.830 * s))
            }
            .stroke(colour, style: StrokeStyle(lineWidth: 0.128 * s, lineCap: .round))

            Path { p in
                p.move(to: junction)
                p.addLine(to: CGPoint(x: armX, y: 0.180 * s))
                p.move(to: junction)
                p.addLine(to: CGPoint(x: armX, y: 0.820 * s))
            }
            .stroke(colour, style: StrokeStyle(lineWidth: 0.118 * s, lineCap: .round))
        }
        .frame(width: s, height: s)
        .shadow(color: glow ? colour.opacity(0.40) : .clear, radius: s * 0.05)
        .accessibilityHidden(true)
    }
}

// MARK: - The mark

/// The logo on its own: the segmented ring with the moment at its centre.
struct KairoMark: View {
    var size: CGFloat = 44
    /// Collapses the whole mark to one colour, for contexts that cannot carry
    /// the warm sweep — a tinted background, a monochrome print, a template icon.
    var monochrome: Color?
    var animatesIn: Bool = false

    var body: some View {
        ZStack {
            SegmentedRing(
                filledStyle: monochrome.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Kairo.sweep),
                emptyStyle: AnyShapeStyle((monochrome ?? Kairo.hairline).opacity(0.16)),
                glow: monochrome ?? Kairo.amber,
                animatesIn: animatesIn)

            Circle()
                .fill(monochrome ?? Kairo.amber)
                .frame(width: size * 0.21, height: size * 0.21)
                .shadow(color: (monochrome ?? Kairo.amber).opacity(0.6), radius: size * 0.09)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - The wordmark

struct KairoWordmark: View {
    var size: CGFloat = 34
    var colour: Color = Kairo.ink

    var body: some View {
        Text("Kairo")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .tracking(size * -0.012)
            .foregroundStyle(colour)
    }
}

// MARK: - The lockup

/// Mark plus wordmark, in the two arrangements the app actually needs: stacked
/// for the launch screen, side by side for a header.
struct KairoLogo: View {
    enum Arrangement { case stacked, horizontal }

    var arrangement: Arrangement = .stacked
    var scale: CGFloat = 1
    var showsTagline = false
    var monochrome: Color?

    private var markSize: CGFloat { (arrangement == .stacked ? 118 : 40) * scale }
    private var wordSize: CGFloat { (arrangement == .stacked ? 40 : 24) * scale }

    var body: some View {
        switch arrangement {
        case .stacked:
            VStack(spacing: 22 * scale) {
                KairoLetter(size: markSize, colour: monochrome ?? Kairo.amber)
                VStack(spacing: 7 * scale) {
                    KairoWordmark(size: wordSize, colour: monochrome ?? Kairo.ink)
                    if showsTagline { tagline }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Kairo")
        case .horizontal:
            HStack(spacing: 10 * scale) {
                KairoLetter(size: markSize, colour: monochrome ?? Kairo.amber)
                KairoWordmark(size: wordSize, colour: monochrome ?? Kairo.ink)
            }
            .accessibilityElement()
            .accessibilityLabel("Kairo")
        }
    }

    private var tagline: some View {
        Text("The right moment, not every moment.")
            .font(.system(size: 12.5 * scale, weight: .medium, design: .rounded))
            .tracking(0.3)
            .foregroundStyle((monochrome ?? Kairo.inkFaint).opacity(monochrome == nil ? 1 : 0.7))
            .multilineTextAlignment(.center)
    }
}

#Preview("Logo") {
    ZStack {
        KairoCanvas()
        VStack(spacing: 40) {
            KairoLogo(showsTagline: true)
            KairoLogo(arrangement: .horizontal)
            HStack(spacing: 20) {
                KairoLetter(size: 56)
                KairoLetter(size: 28)
                KairoMark(size: 56)
                KairoMark(size: 28)
                KairoMark(size: 28, monochrome: Kairo.teal)
            }
        }
    }
}
