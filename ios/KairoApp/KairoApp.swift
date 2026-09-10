import SwiftUI
import KairoKit

@main
struct KairoApp: App {
    // Which adapters are bound is a decision, not a constant. This read
    // `.preview` unconditionally, which is why the app on a real phone showed the
    // report's Tuesday afternoon — a frozen clock and a stub health port — no
    // matter whose wrist it was on. See Composition/DataSource.swift.
    @State private var source = DataSource.current
    @State private var model = DataSource.current.makeModel()

    var body: some Scene {
        WindowGroup {
            // `bootstrap()` is awaited inside the startup view, which stays up
            // until it finishes — see Design/KairoSplash.swift.
            KairoStartup { RootView() }
                .environment(model)
                // The environment is fixed when `AppModel` is built, so changing
                // the preference alone would leave the old clock and the old
                // health port in place and the screen would not move. Rebuild,
                // and let `.id` re-run the startup task so `bootstrap()` fires
                // against the new adapters.
                .id(source)
                // Simulator-only, opt-in, and a no-op without an explicit launch
                // flag — see Adapters/HealthKitSeeder.swift for the guards. It
                // exists because the HealthKit read paths cannot be executed
                // against an empty Health store, and a simulator has one.
                .task {
                    if let report = await KairoHealthSeeding.runIfRequested() {
                        print(report)
                    }
                }
                .onReceive(NotificationCenter.default
                    .publisher(for: .kairoDataSourceChanged)) { _ in
                    let next = DataSource.current
                    guard next != source else { return }
                    model = next.makeModel()
                    source = next
                }
        }
    }
}
