import SwiftUI

// Waiting states.
//
// Three of them, because three different waits want different shapes: a screen
// with nothing on it yet, content whose layout is already known, and a row that
// is working while the rest of the screen is not. All three are the brand mark
// rather than a stock spinner - `SegmentedRing` from KairoLogo.swift is Kairo's
// ring, so Kairo's loader is that ring in motion.
//
// Every one of them honours Reduce Motion. A loader is the one thing on screen
// that never stops moving, so it is the worst thing to leave spinning for
// someone who asked the system to stop.

// MARK: - Screen-level

/// The mark, turning. For a screen that has nothing to show yet.
struct KairoLoader: View {
    var size: CGFloat = 56
    var label: String?
    var tint: Color = Kairo.amber

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 14) {
            ring
            if let label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Kairo.inkFaint)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var ring: some View {
        // Two lit segments out of six read as motion at any size; five-of-three,
        // the mark's own proportions, reads as a nearly-full ring instead.
        let mark = SegmentedRing(
            segments: 6, filled: 2, weight: 0.10, gapDegrees: 16,
            filledStyle: AnyShapeStyle(Kairo.fade(tint)),
            emptyStyle: AnyShapeStyle(Kairo.hairline.opacity(0.10)),
            glow: tint,
            rotation: .degrees(turning ? 360 : 0))
            .frame(width: size, height: size)

        if reduceMotion {
            mark
                .opacity(breathing ? 1 : 0.45)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: breathing)
                .onAppear { breathing = true }
        } else {
            mark
                .animation(.linear(duration: 1.3).repeatForever(autoreverses: false),
                           value: turning)
                .onAppear { turning = true }
        }
    }
}

/// Fills the space a screen's content will occupy, so the first real frame does
/// not arrive as a jump.
struct KairoLoadingScreen: View {
    var label: String

    var body: some View {
        VStack {
            Spacer()
            KairoLoader(size: 62, label: label)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(KairoCanvas())
    }
}

// MARK: - Skeletons

/// One placeholder bar. Used where the shape of the content is already known,
/// which is most of this app - a stat tile is a stat tile before the number
/// lands, so nothing needs to move when it does.
struct KairoSkeleton: View {
    var width: CGFloat?
    var height: CGFloat = 13
    var radius: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Kairo.hairline.opacity(0.10))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay { if !reduceMotion { shimmer } }
            .clipShape(shape)
            .accessibilityHidden(true)
    }

    private var shimmer: some View {
        GeometryReader { geo in
            LinearGradient(colors: [.clear, Kairo.hairline.opacity(0.16), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: max(40, geo.size.width * 0.5))
                .offset(x: sweep ? geo.size.width : -geo.size.width * 0.5)
                .animation(.linear(duration: 1.25).repeatForever(autoreverses: false),
                           value: sweep)
                .onAppear { sweep = true }
        }
    }
}

/// A paragraph's worth of placeholder, last line short so it reads as prose.
struct KairoSkeletonText: View {
    var lines: Int = 3
    var height: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<max(lines, 1), id: \.self) { i in
                KairoSkeleton(width: i == lines - 1 && lines > 1 ? 120 : nil, height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

// MARK: - Inline

/// Small enough to sit on a line of text or inside a button.
struct KairoInlineLoader: View {
    var size: CGFloat = 15
    var tint: Color = Kairo.inkSoft
    var label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 7) {
            ring
            if let label {
                Text(label).font(.caption).foregroundStyle(Kairo.inkFaint)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private var ring: some View {
        let mark = SegmentedRing(
            segments: 4, filled: 1, weight: 0.16, gapDegrees: 26,
            filledStyle: AnyShapeStyle(tint),
            emptyStyle: AnyShapeStyle(Kairo.hairline.opacity(0.12)),
            glow: nil,
            rotation: .degrees(turning ? 360 : 0))
            .frame(width: size, height: size)

        if reduceMotion {
            mark
                .opacity(breathing ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: breathing)
                .onAppear { breathing = true }
        } else {
            mark
                .animation(.linear(duration: 1.1).repeatForever(autoreverses: false),
                           value: turning)
                .onAppear { turning = true }
        }
    }
}

#Preview("Loaders") {
    ZStack {
        KairoCanvas()
        VStack(spacing: 34) {
            KairoLoader(size: 62, label: "Reading your day")
            HStack(spacing: 26) {
                KairoLoader(size: 34, tint: Kairo.teal)
                KairoLoader(size: 24, tint: Kairo.violet)
                KairoInlineLoader(label: "Screening")
            }
            VStack(alignment: .leading, spacing: 12) {
                KairoSkeleton(width: 90, height: 26)
                KairoSkeletonText(lines: 3)
            }
            .kairoCard()
            .padding(.horizontal, 20)
        }
    }
}
