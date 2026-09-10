import Foundation
import KairoKit

/// CF7. The outcome history receptivity is learned from, kept on this phone.
///
/// On-device on purpose: what somebody dismisses and when is a behavioural
/// record, and NFR5's argument for keeping health memories local applies at
/// least as strongly to a log of when they are ignoring their phone.
///
/// A file rather than `UserDefaults`: this grows with use, and `UserDefaults` is
/// loaded whole on first access.
public final class StoredOutcomeLog: NudgeOutcomeLog, @unchecked Sendable {
    /// Enough history for the hour buckets to fill without the file growing
    /// without bound. Oldest go first — receptivity that cannot forget a habit
    /// somebody has since dropped is not learning.
    public static let limit = 500

    private let url: URL
    private let lock = NSLock()
    private var cache: [NudgeOutcome]

    public init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL()
        self.url = resolved
        self.cache = Self.load(from: resolved)
    }

    public func outcomes() -> [NudgeOutcome] {
        lock.lock(); defer { lock.unlock() }
        return cache
    }

    public func append(_ outcome: NudgeOutcome) {
        lock.lock()
        cache.append(outcome)
        if cache.count > Self.limit { cache.removeFirst(cache.count - Self.limit) }
        let snapshot = cache
        lock.unlock()
        Self.write(snapshot, to: url)
    }

    // MARK: - Storage

    private static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
        return base.appendingPathComponent("kairo-nudge-outcomes.json")
    }

    private static func load(from url: URL) -> [NudgeOutcome] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([NudgeOutcome].self, from: data)) ?? []
    }

    /// Written whole and atomically. A truncated log would read as a user who
    /// stopped responding, which the model would learn from.
    private static func write(_ outcomes: [NudgeOutcome], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(outcomes) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
