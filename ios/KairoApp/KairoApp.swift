import SwiftUI
import KairoKit

@main
struct KairoApp: App {
    @State private var model = AppModel(environment: .preview)

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
