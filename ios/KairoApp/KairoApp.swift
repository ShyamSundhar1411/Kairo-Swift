import SwiftUI
import KairoKit

@main
struct KairoApp: App {
    // One environment, all of it real. This used to read `.preview` — a frozen
    // clock, a stub health port and three seeded memories — which is why the app
    // on a device opened on the report's Tuesday whoever was wearing it.
    @State private var model = AppModel(environment: .live)

    /// Set by `WelcomeTour` when it finishes. The tour owns its own "seen"
    /// state; this only reads it to decide which of the two roots to build.
    @AppStorage("kairo.tour.completed") private var tourCompleted = false

    var body: some Scene {
        WindowGroup {
            // The tour runs BEFORE bootstrap, not over it. bootstrap() reads
            // HealthKit, and the first read triggers iOS's permission sheet —
            // so launching straight into it meant the very first thing a new
            // user saw was a system dialog asking for their health data, with
            // nothing on screen explaining who was asking or why. Explain, then
            // ask, in that order.
            if tourCompleted {
                KairoStartup { RootView() }
                    .environment(model)
                    // Simulator-only, opt-in, and a no-op without an explicit launch
                    // flag — see Adapters/HealthKitSeeder.swift for the guards. It
                    // exists because the HealthKit read paths cannot be executed
                    // against an empty Health store, and a simulator has one.
                    .task {
                        if let report = await KairoHealthSeeding.runIfRequested() {
                            print(report)
                        }
                    }
            } else {
                // Handed the model explicitly. The tour sets AG-1's ceiling
                // (SCRUM-21), so it needs one — and taking it as a parameter
                // means it cannot be presented without one, which an
                // `@Environment` lookup allowed right up until it trapped at
                // runtime on the first launch of a fresh install.
                //
                // It does not bootstrap. Constructing the model is cheap and
                // reads nothing; `bootstrap()` is what touches HealthKit, and
                // running before that is the entire reason the tour exists.
                WelcomeTour(app: model)
            }
        }
    }
}
