import SwiftUI
import KairoKit

/// The startup sequence.
///
/// iOS paints the static launch screen (`UILaunchScreen` in apps/project.yml:
/// `LaunchBackground` behind the `LaunchMark` image) before any of our code
/// runs. This view opens on visually the same thing in the same place, then
/// brings it to life and dissolves into the app — so there is no seam where the
/// system's screen hands over to ours.
///
/// It covers real work rather than a timer. `AppModel.bootstrap()` loads the
/// memory store and runs the first arbitration pass; the splash is up for
/// exactly as long as that takes, with a floor so it cannot flash and vanish,
/// and no ceiling that would keep a ready app hidden.
struct KairoStartup<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder var content: Content

    @State private var booted = false
    @State private var showing = true
    @State private var lit = false

    /// Long enough to read as deliberate, short enough not to be a wait.
    private let floor: Duration = .milliseconds(900)

    var body: some View {
        ZStack {
            content
                .opacity(showing ? 0 : 1)
                .scaleEffect(showing && !reduceMotion ? 0.985 : 1)

            if showing {
                splash
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            // The floor and the work run together, so a slow bootstrap costs
            // nothing extra and a fast one still gets its moment.
            async let settle: Void = Task.sleep(for: floor)
            await model.bootstrap()
            try? await settle
            booted = true
            withAnimation(reduceMotion ? .easeInOut(duration: 0.28)
                                       : .spring(response: 0.55, dampingFraction: 0.9)) {
                showing = false
            }
        }
    }

    private var splash: some View {
        ZStack {
            KairoCanvas()
            VStack(spacing: 30) {
                // Sits where the static launch mark sat: same 160pt box, centred.
                KairoLetter(size: 160)
                    .scaleEffect(lit || reduceMotion ? 1 : 0.96)
                VStack(spacing: 7) {
                    KairoWordmark(size: 40)
                    Text("The right moment, not every moment.")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .tracking(0.3)
                        .foregroundStyle(Kairo.inkFaint)
                }
                .opacity(lit ? 1 : 0)
                .offset(y: lit || reduceMotion ? 0 : 8)
            }
            .accessibilityElement()
            .accessibilityLabel("Kairo. The right moment, not every moment.")
        }
        .onAppear {
            // The mark is already on screen from the launch image; only the
            // wording is new, so only the wording arrives.
            withAnimation(.easeOut(duration: 0.45).delay(reduceMotion ? 0 : 0.28)) { lit = true }
        }
    }
}

#Preview("Startup") {
    KairoStartup { RootView() }
        .environment(AppModel(environment: .preview))
}
