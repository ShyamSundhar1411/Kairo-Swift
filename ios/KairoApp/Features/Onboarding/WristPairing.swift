import SwiftUI
import KairoKit

/// The pairing page, drawn from the live link rather than from an illustration.
///
/// The watch does **not** authenticate separately and does not need to: it never
/// contacts the backend. It talks to this phone over WatchConnectivity, and the
/// pairing iOS established is what says whose wrist it is. That is written down
/// as AS-15 in `docs/TRUST-BOUNDARIES.md`, because an assumption that lives only
/// in somebody's head is not a design decision.
///
/// What this screen is for, then, is not a credential. It is making a trust
/// boundary visible to the person relying on it, and giving them one place where
/// "is it actually connected?" has an answer that is not a guess.
struct WristPairing: View {
    let app: AppModel
    /// Pulses when the link first comes up, so the connection is a moment
    /// rather than a label that was already true when the page appeared.
    @State private var arrived = false

    private var link: WristLink { app.wristLink }

    var body: some View {
        VStack(spacing: 26) {
            diagram
            status
        }
        .task {
            app.observeWristLink()
        }
        .onChange(of: link) { _, now in
            guard now == .connected else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { arrived = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watch connection")
        .accessibilityValue(spoken)
    }

    // MARK: - The two devices, and what is between them

    private var diagram: some View {
        HStack(spacing: 0) {
            phone
            wire
            watch
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
    }

    private var phone: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Kairo.inkSoft, lineWidth: 3)
            .frame(width: 66, height: 116)
            .overlay(alignment: .top) {
                Capsule().fill(Kairo.inkSoft).frame(width: 20, height: 4).padding(.top, 9)
            }
    }

    private var watch: some View {
        VStack(spacing: 0) {
            Capsule().fill(tint.opacity(0.45)).frame(width: 26, height: 16)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(tint, lineWidth: 3)
                .frame(width: 58, height: 70)
                .overlay {
                    // The one thing the watch is for, drawn rather than labelled.
                    Image(systemName: carries ? "drop.fill" : "questionmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }
            Capsule().fill(tint.opacity(0.45)).frame(width: 26, height: 16)
        }
        .scaleEffect(arrived && link == .connected ? 1.0 : 0.94)
    }

    /// Dashed and drifting while it is looking; solid once it is not.
    private var wire: some View {
        ZStack {
            Capsule()
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: carries ? [] : [7, 9]))
                .foregroundStyle(carries ? tint : Kairo.inkFaint)
                .frame(height: 3)
            if carries {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .offset(x: arrived ? 40 : -40)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                               value: arrived)
            }
        }
        .frame(width: 128)
        .padding(.horizontal, 14)
    }

    // MARK: - What it says

    private var status: some View {
        VStack(spacing: 10) {
            Text(headline)
                .font(.kairoHeadline)
                .foregroundStyle(carries ? tint : Kairo.ink)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            Text(detail)
                .font(.kairoCaption)
                .foregroundStyle(Kairo.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
    }

    private var carries: Bool { link.carriesTaps }

    private var tint: Color {
        switch link {
        case .connected:                     Kairo.teal
        case .outOfReach:                    Kairo.amber
        case .noWatch, .unsupported:         Kairo.inkFaint
        case .appNotInstalled, .connecting:  Kairo.amber
        }
    }

    private var headline: String {
        switch link {
        case .connected:       "Your watch is connected."
        case .outOfReach:      "Paired, and out of range."
        case .appNotInstalled: "Install Kairo on your watch."
        case .noWatch:         "No watch paired to this iPhone."
        case .unsupported:     "This device has no watch link."
        case .connecting:      "Looking for your watch…"
        }
    }

    /// Every branch says what happens next, and none of them says "error".
    /// Not owning a watch is the common case and is not a failure.
    private var detail: String {
        switch link {
        case .connected:
            "Tap water on the wrist and it lands here. Interruptions Kairo allows "
            + "arrive there too, so you can answer one without taking the phone out."
        case .outOfReach:
            "Nothing is lost. Taps made on the watch are held and re-sent the next "
            + "time the two are together."
        case .appNotInstalled:
            "Open the Watch app on your iPhone and install Kairo. It will connect "
            + "here on its own — there is no code to enter, and no second sign-in: "
            + "the watch is yours because iOS paired it."
        case .noWatch:
            "Everything works without one. Water is logged here, and the one or two "
            + "interruptions a day arrive as notifications instead."
        case .unsupported:
            "Everything works without one. This is the phone's own account either "
            + "way."
        case .connecting:
            "This takes a second. If you do not have an Apple Watch, skip — nothing "
            + "below depends on it."
        }
    }

    private var spoken: String { "\(headline) \(detail)" }
}
