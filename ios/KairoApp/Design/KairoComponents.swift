import SwiftUI
import KairoKit

// The shared vocabulary every screen is assembled from. Feature views compose
// these; they do not draw their own chrome.

// MARK: - Card

struct KairoCard: ViewModifier {
    var padding: CGFloat = Kairo.Space.gutter
    var radius: CGFloat = Kairo.Radius.card
    /// Non-nil paints a faint wash and a brighter edge in that colour, used when
    /// a card carries a state the user should notice.
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                shape
                    .fill(.ultraThinMaterial)
                    .overlay { shape.fill(Kairo.cardTint.opacity(0.55)) }
                    .overlay { shape.fill((tint ?? .clear).opacity(0.09)) }
                    .overlay {
                        shape.strokeBorder(
                            (tint ?? Kairo.hairline).opacity(tint == nil ? 0.10 : 0.35),
                            lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
            }
    }
}

extension View {
    func kairoCard(padding: CGFloat = Kairo.Space.gutter,
                   radius: CGFloat = Kairo.Radius.card,
                   tint: Color? = nil) -> some View {
        modifier(KairoCard(padding: padding, radius: radius, tint: tint))
    }

    /// Turns a `List` into a stack of cards on the canvas.
    func kairoListRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: Kairo.Space.stack,
                                      bottom: 5, trailing: Kairo.Space.stack))
    }
}

// MARK: - Headers

/// Screen header: a small eyebrow, a large rounded title, an optional control.
struct KairoHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    @ViewBuilder var trailing: Trailing

    /// At an accessibility size the title and a trailing control cannot share a
    /// 375pt line: the title lost, and "Good evening" rendered as "Good eve…".
    /// A screen's own name is the last thing that should be abbreviated, so the
    /// control moves below it instead.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let words = VStack(alignment: .leading, spacing: 2) {
            Text(eyebrow.uppercased())
                .font(.kairoLabel).tracking(typeSize.isAccessibilitySize ? 0.4 : 1.1)
                .foregroundStyle(Kairo.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
            Text(title)
                .font(.kairoTitle)
                .foregroundStyle(Kairo.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                words
                trailing
            }
        } else {
            HStack(alignment: .center) {
                words
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

extension KairoHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String) {
        self.init(eyebrow: eyebrow, title: title, trailing: { EmptyView() })
    }
}

struct SectionHeader: View {
    let title: String
    var icon: String?
    var trailing: String?
    var tint: Color = Kairo.inkFaint

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
            }
            Text(title.uppercased()).font(.kairoLabel).tracking(1.1)
            Spacer()
            if let trailing {
                Text(trailing).font(.kairoLabel).tracking(0.6).foregroundStyle(Kairo.inkFaint)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
    }
}

/// The quiet paragraph that explains a policy rather than a number. Kairo makes
/// a lot of promises about restraint; they get a consistent, unshouty container.
struct TrustNote: View {
    let text: String
    var icon: String = "hand.raised"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Kairo.inkFaint)
                .padding(.top, 1)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Kairo.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Kairo.Radius.inner, style: .continuous)
                .fill(Kairo.hairline.opacity(0.04))
        }
    }
}

// MARK: - Pills and chips

struct Pill: View {
    let text: String
    var icon: String?
    var tint: Color = Kairo.inkSoft
    var solid = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let icon { Image(systemName: icon).font(.kairoGlyph(9)) }
            // Wraps when the row it is on is narrower than the label. A pill is
            // a container for a short phrase, not a promise that the phrase is
            // short at every text size.
            Text(text).font(.kairoLabel).tracking(0.4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(solid ? Color.white : tint)
        .background {
            Capsule().fill(solid ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
        }
        .overlay { if !solid { Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5) } }
    }
}

/// Which of the five roles said this. A disc of the role's colour, so a screen
/// full of claims reads as coming from different places.
struct AgentChip: View {
    let agent: String
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Kairo.icon(forAgent: agent))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Kairo.colour(forAgent: agent)))
            if !compact {
                Text(Kairo.shortName(forAgent: agent))
                    .font(.kairoLabel).tracking(0.4)
                    .foregroundStyle(Kairo.colour(forAgent: agent))
            }
        }
        .accessibilityLabel("\(Kairo.shortName(forAgent: agent)) role")
    }
}

// MARK: - Meters

struct ScoreMeter: View {
    let value: Double
    var tint: Color = Kairo.amber
    var height: CGFloat = 6

    var body: some View {
        let v = min(max(value, 0), 1)
        Capsule()
            .fill(Kairo.hairline.opacity(0.10))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Kairo.fade(tint))
                        .frame(width: max(height, geo.size.width * v))
                }
            }
            .accessibilityHidden(true)
    }
}

struct MetricRing: View {
    let progress: Double
    var tint: Color = Kairo.amber
    var icon: String?
    var centreText: String?
    var size: CGFloat = 62
    var lineWidth: CGFloat = 7

    var body: some View {
        let p = min(max(progress, 0), 1)
        ZStack {
            Circle()
                .stroke(Kairo.hairline.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: p)
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint],
                                        center: .center,
                                        startAngle: .degrees(-90), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let centreText {
                Text(centreText)
                    .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                    .foregroundStyle(Kairo.ink)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: size * 0.28, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: p)
    }
}

/// The hero of the Today screen: one arc segment per interruption the day is
/// allowed to contain, warm where it has been spent and dark where it has not.
///
/// The ring itself is `SegmentedRing` from KairoLogo.swift — the same shape as
/// the app icon and the brand mark, at a different size. The dial is that shape
/// with today's real numbers in it, which is the whole point of the mark.
struct AttentionDial: View {
    let spent: Int
    let total: Int
    var size: CGFloat = 132

    private var remaining: Int { max(0, total - spent) }

    var body: some View {
        ZStack {
            SegmentedRing(segments: total, filled: spent,
                          weight: 0.075, gapDegrees: 8, animatesIn: true)
            VStack(spacing: -2) {
                Text("\(remaining)")
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(Kairo.ink)
                    .contentTransition(.numericText())
                Text("left")
                    .font(.kairoLabel).tracking(1.2)
                    .foregroundStyle(Kairo.inkFaint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("\(spent) of \(total) interruptions spent today, \(remaining) left")
    }
}

// MARK: - Tiles

struct StatTile: View {
    /// nil while the number is still being read. The tile keeps its size either
    /// way, so nothing on the screen moves when the value lands — and an unknown
    /// reading is never drawn as a zero.
    let value: String?
    let caption: String
    var icon: String
    var tint: Color = Kairo.inkSoft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.15)))
            if let value {
                Text(value)
                    .font(.kairoNumber)
                    .foregroundStyle(Kairo.ink)
                    // Shrinks rather than truncating. A measurement cut off at
                    // an ellipsis is worse than a small one, and a tile three
                    // across has nowhere to grow sideways.
                    .lineLimit(1).minimumScaleFactor(0.5)
            } else {
                KairoSkeleton(width: 58, height: 22)
                    .padding(.vertical, 3)
            }
            // No `lineLimit(2)`. "sitting unbroken" is two lines at the
            // default size and four at accessibility XXXL, and a fixed limit
            // turned the fourth into an ellipsis.
            Text(caption)
                .font(.kairoCaption)
                .foregroundStyle(Kairo.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .kairoCard(padding: 14, radius: Kairo.Radius.inner)
    }
}

/// A tappable card used where the demo needs the user to pick a path.
struct ChoiceCard: View {
    let title: String
    let subtitle: String
    var icon: String
    var tint: Color = Kairo.teal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.kairoHeadline).foregroundStyle(Kairo.ink)
                    Text(subtitle).font(.caption).foregroundStyle(Kairo.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Kairo.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .kairoCard(padding: 14, radius: Kairo.Radius.inner)
        }
        .buttonStyle(.kairoPress)
    }
}

// MARK: - Button styles

struct KairoProminentButtonStyle: ButtonStyle {
    var tint: Color = Kairo.amber

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kairoHeadline)
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Kairo.fade(tint)))
            .shadow(color: tint.opacity(0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct KairoSoftButtonStyle: ButtonStyle {
    var tint: Color = Kairo.inkSoft

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kairoHeadline)
            .foregroundStyle(tint)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// No chrome of its own — just the press feedback, for buttons that already sit
/// inside a card.
struct KairoPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == KairoProminentButtonStyle {
    static var kairoProminent: KairoProminentButtonStyle { .init() }
    static func kairoProminent(_ tint: Color) -> KairoProminentButtonStyle { .init(tint: tint) }
}

extension ButtonStyle where Self == KairoSoftButtonStyle {
    static var kairoSoft: KairoSoftButtonStyle { .init() }
    static func kairoSoft(_ tint: Color) -> KairoSoftButtonStyle { .init(tint: tint) }
}

extension ButtonStyle where Self == KairoPressButtonStyle {
    static var kairoPress: KairoPressButtonStyle { .init() }
}

// MARK: - Hero rows

/// A fixed-width graphic beside a block of prose — and above it instead, once
/// the prose needs the whole screen.
///
/// Kairo's hero cards are all this shape: a dial, a ring or a loader on the
/// left, the sentence that explains it on the right. At 375 points and an
/// accessibility text size the right-hand column is about 190 points wide,
/// which is four or five characters a line. Stacking is not a worse version of
/// the design; it is the same design given the room the words need.
struct AdaptiveHeroRow<Graphic: View, Detail: View, Trailing: View>: View {
    let stacked: Bool
    var spacing: CGFloat = Kairo.Space.gutter
    @ViewBuilder var graphic: Graphic
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: spacing) {
                graphic
                detail
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: spacing) {
                graphic
                detail
                Spacer(minLength: 0)
                trailing
            }
        }
    }
}

extension AdaptiveHeroRow where Trailing == EmptyView {
    init(stacked: Bool, spacing: CGFloat = Kairo.Space.gutter,
         @ViewBuilder graphic: () -> Graphic,
         @ViewBuilder detail: () -> Detail) {
        self.init(stacked: stacked, spacing: spacing,
                  graphic: graphic, detail: detail, trailing: { EmptyView() })
    }
}
