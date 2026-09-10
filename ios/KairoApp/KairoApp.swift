import SwiftUI
import KairoKit

@main
struct KairoApp: App {
    // One environment, all of it real. This used to read `.preview` — a frozen
    // clock, a stub health port and three seeded memories — which is why the app
    // on a device opened on the report's Tuesday whoever was wearing it.
    @State private var model = AppModel(environment: .live)

    var body: some Scene {
        WindowGroup {
            // `bootstrap()` is awaited inside the startup view, which stays up
            // until it finishes — see Design/KairoSplash.swift.
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
        }
    }
}
