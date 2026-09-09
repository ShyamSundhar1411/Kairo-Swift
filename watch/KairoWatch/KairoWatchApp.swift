import SwiftUI
import KairoKit

@main
struct KairoWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
        }
    }
}
