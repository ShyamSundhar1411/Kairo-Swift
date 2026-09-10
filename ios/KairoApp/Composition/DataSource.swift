import Foundation

/// Which set of adapters `@main` binds: this phone, or the recorded scenario.
///
/// `@main` hard-coded `.preview` for the whole of Stage 1. That is why the app
/// on a real device kept showing 6h12m of sleep and 82 minutes of sitting no
/// matter what the wearer had actually done: the clock was a `FixedClock` frozen
/// at the report's Tuesday 15:40, and the health port was `StubHealthDataSource`.
///
/// Connecting the backend could not have fixed it, and it is worth being precise
/// about why: the agents decide *which* nudge wins and how it is worded. What the
/// readings are is a question for the adapters bound here. A perfectly healthy
/// backend arbitrating over stub readings still returns an answer about a day
/// nobody lived.
enum DataSource: String, CaseIterable, Identifiable {
    /// This phone: system clock, HealthKit, Open Food Facts over the network.
    case live
    /// The Stage 1 scenario, frozen and offline. What the report's figures and
    /// the recorded video open on, and what makes them reproducible on any
    /// machine at any hour.
    case demo

    var id: String { rawValue }

    private static let key = "kairo.dataSource"

    /// Device defaults to `.live`, simulator to `.demo`.
    ///
    /// A simulator has an empty Health store, so `.live` there shows a screen of
    /// honest blanks — correct, and useless to demo from. The default follows
    /// where the app is running; a stored choice overrides it either way.
    static var current: DataSource {
        if let raw = UserDefaults.standard.string(forKey: key),
           let stored = DataSource(rawValue: raw) { return stored }
        return isSimulator ? .demo : .live
    }

    static func store(_ value: DataSource) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
        NotificationCenter.default.post(name: .kairoDataSourceChanged, object: nil)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var environment: AppEnvironment {
        switch self {
        case .live: return .live
        case .demo: return .preview
        }
    }

    /// Only the demo opens on the report's coverage figures. See `AppModel.init`.
    var seedsScenario: Bool { self == .demo }

    func makeModel() -> AppModel {
        AppModel(environment: environment, seedingScenario: seedsScenario)
    }

    var title: String { self == .live ? "This iPhone" : "Demo scenario" }

    var detail: String {
        switch self {
        case .live:
            return "System clock, and sleep and movement read from Health. "
                 + "Screens stay blank where Health has nothing — that is the reading, not a bug."
        case .demo:
            return "The Stage 1 scenario, frozen at Tue 25 Aug 15:40 and offline. "
                 + "Reproducible, and the same picture the report's figures show."
        }
    }
}

extension Notification.Name {
    /// Posted when the bound adapters must change. `@main` rebuilds `AppModel`
    /// on this: the environment is fixed at construction, so flipping the
    /// preference alone would leave the old clock and the old health port in
    /// place and the screen would not move.
    static let kairoDataSourceChanged = Notification.Name("kairo.dataSourceChanged")
}
