import Foundation
import KairoKit

/// Talks to the Kairo agent backend (../../backend, Python on LangGraph).
///
/// The app works without it. When no server is configured, or the one configured
/// cannot be reached, `AppModel` falls back to the on-device arbiter — which is
/// what NFR9 asks for and what the cross-language conformance test keeps honest.
///
/// The fallback is deliberately *visible*: `ConnectionState` is surfaced in the
/// UI, because an app that silently drops from five reasoning agents to a local
/// heuristic and looks identical either way is the same silent-failure class the
/// backend's `unavailable` vs `ungrounded` split exists to prevent.
public struct RemoteAgentClient: Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let token: String?

    public init(baseURL: URL, token: String? = nil, timeout: TimeInterval = 45) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public enum ClientError: LocalizedError {
        case http(Int, String)
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case let .http(code, body): "the backend returned \(code): \(body)"
            case let .malformed(what): "the backend's reply could not be read: \(what)"
            }
        }
    }

    // MARK: - Health

    public struct Health: Sendable {
        public let mode: String
        public let promptVersion: String
        public let roles: [String]
        public let runtime: String
    }

    public func health() async throws -> Health {
        let json = try await send(request(for: "health"))
        return Health(mode: json["mode"] as? String ?? "unknown",
                      promptVersion: json["promptVersion"] as? String ?? "unknown",
                      roles: json["roles"] as? [String] ?? [],
                      runtime: json["runtime"] as? String ?? "unknown")
    }

    // MARK: - CF7

    /// What the five roles produced, translated back into domain values.
    ///
    /// NFR5 governs what goes out: coverage *counts* and current readings, never
    /// raw HealthKit series and never a health-sensitive memory.
    public struct Arbitration: Sendable {
        public let delivered: [RemoteNudge]
        public let suppressed: [RemoteNudge]
        public let spent: Int
        public let spentNothing: Bool
        public let recordID: String
        public let contributingRoles: [String]
        public let citedMemories: [(id: String, confidence: Double)]
        public let serviceTier: String
    }

    public struct RemoteNudge: Sendable, Identifiable {
        public let id: String
        public let nudgeClass: String
        public let originAgent: String
        public let text: String
        public let score: Double
        public let receptivity: Double
        public let channel: NudgeChannelKind?
        public let suppressionReason: SuppressionReason?
        /// Section 7.1: a cost suppression must never be shown to the user as
        /// restraint. The backend sends this so the client cannot get it wrong.
        public let presentableAsRestraint: Bool
    }

    /// `now` is the device's clock, not the server's. Receptivity depends on the
    /// hour, so judging it against whatever time the backend happens to be in
    /// makes the score depend on a clock the user never sees — and makes a
    /// recorded demo unreplayable, which is the whole reason the domain takes
    /// time through a port instead of reading it.
    public func arbitrate(userID: String, now: Date, schedule: NudgeSchedule,
                          coverage: DayCoverage, observations: Observations,
                          quietHours: Bool, profile: CapabilityProfile) async throws -> Arbitration {
        var coveragePayload: [String: Any] = [:]
        for domain in CoverageDomain.allCases {
            if let m = coverage.metrics[domain] {
                coveragePayload[domain.rawValue] = ["observed": m.observedCount,
                                                    "expected": m.expectedCount]
            }
        }
        let json = try await send(request(for: "v1/arbitrate", body: [
            "userID": userID,
            "now": Self.instant.string(from: now),
            "dayStart": Self.instant.string(from: schedule.dayStart),
            "dailyBudget": schedule.dailyBudget,
            "spent": schedule.spent,
            "quietHours": quietHours,
            "capabilities": profile.available.map(\.rawValue),
            "coverage": coveragePayload,
            "observations": observations.payload,
        ]))

        let record = json["record"] as? [String: Any] ?? [:]
        return Arbitration(
            delivered: (json["delivered"] as? [[String: Any]] ?? []).compactMap(Self.nudge),
            suppressed: (json["suppressed"] as? [[String: Any]] ?? []).compactMap(Self.nudge),
            spent: json["spent"] as? Int ?? schedule.spent,
            spentNothing: json["spentNothing"] as? Bool ?? true,
            recordID: record["id"] as? String ?? "",
            contributingRoles: (record["fragments"] as? [[String: Any]] ?? [])
                .compactMap { $0["agent"] as? String },
            citedMemories: (record["citations"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["memoryID"] as? String else { return nil }
                return (id, $0["confidenceAtCitation"] as? Double ?? 0)
            },
            serviceTier: json["serviceTier"] as? String ?? "unknown")
    }

    private static func nudge(_ raw: [String: Any]) -> RemoteNudge? {
        guard let id = raw["bidID"] as? String,
              let cls = raw["class"] as? String,
              let text = raw["text"] as? String else { return nil }
        return RemoteNudge(
            id: id, nudgeClass: cls,
            originAgent: raw["originAgent"] as? String ?? "",
            text: text,
            score: raw["score"] as? Double ?? 0,
            receptivity: raw["receptivity"] as? Double ?? 0,
            channel: (raw["channel"] as? String).flatMap(NudgeChannelKind.init(rawValue:)),
            suppressionReason: (raw["suppressionReason"] as? String)
                .flatMap(SuppressionReason.init(rawValue:)),
            presentableAsRestraint: raw["presentableAsRestraint"] as? Bool ?? true)
    }

    // MARK: - CF1

    public struct MealAnalysis: Sendable {
        public let state: String
        public let grounded: Bool
        /// Set only when the analysis did not happen. `ungrounded` with no
        /// failure is the analyst having looked and declined to quantify, which
        /// is the feature; this is the system being unable to answer.
        public let failure: String?
        public let clarifyingQuestion: String?
        public let items: [FoodItem]
        public var totalKilojoules: Double { items.reduce(0) { $0 + $1.facts.kilojoules } }
    }

    public func analyseMeal(userID: String, imageData: Data, mediaType: String,
                            hint: String?, coverage: DayCoverage) async throws -> MealAnalysis {
        var body: [String: Any] = [
            "userID": userID,
            "imageBase64": imageData.base64EncodedString(),
            "mediaType": mediaType,
        ]
        if let hint { body["hint"] = hint }
        let json = try await send(request(for: "v1/meals/analyse", body: body))
        let items = (json["items"] as? [[String: Any]] ?? []).compactMap { raw -> FoodItem? in
            guard let name = raw["name"] as? String else { return nil }
            return FoodItem(
                name: name, grams: raw["grams"] as? Double ?? 0,
                facts: NutritionFacts(kilojoules: raw["kilojoules"] as? Double ?? 0,
                                      proteinGrams: raw["proteinGrams"] as? Double ?? 0),
                confidence: raw["confidence"] as? Double ?? 0.5)
        }
        return MealAnalysis(
            state: json["state"] as? String ?? "unavailable",
            grounded: json["grounded"] as? Bool ?? false,
            failure: json["failure"] as? String,
            clarifyingQuestion: json["clarifyingQuestion"] as? String,
            items: items)
    }

    // MARK: - CF12

    public struct Explanation: Sendable {
        public let summary: String
        public let roleContributions: [(role: String, plainLanguage: String)]
        public let whatItDidNotSay: String
        public let limits: String?
    }

    public func explain(recordID: String, userID: String) async throws -> Explanation {
        let json = try await send(request(for: "v1/decision-records/\(recordID)/explain",
                                          query: ["userID": userID]))
        return Explanation(
            summary: json["summary"] as? String ?? "",
            roleContributions: (json["roleContributions"] as? [[String: Any]] ?? []).compactMap {
                guard let role = $0["role"] as? String,
                      let plain = $0["plainLanguage"] as? String else { return nil }
                return (role, plain)
            },
            whatItDidNotSay: json["whatItDidNotSay"] as? String ?? "",
            limits: json["limits"] as? String)
    }

    public func annotate(recordID: String, author: String, text: String) async throws {
        _ = try await send(request(for: "v1/decision-records/annotate",
                                   body: ["recordID": recordID, "author": author, "text": text]))
    }

    // MARK: - Transport

    private func request(for path: String, query: [String: String] = [:],
                         body: [String: Any]? = nil) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Emits the offset, not "Z".
    ///
    /// Receptivity is judged on the hour of the user's day — a memory here says
    /// "ignores nudges before 9am". Sending 15:40 Sydney as 05:40Z hands the
    /// backend an hour of 5, and the roles correctly decline to bid at what they
    /// are told is dawn. The offset is the part that carries the meaning.
    private static let instant: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformed("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode,
                                   String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformed("top level is not an object")
        }
        return object
    }
}

private extension Observations {
    /// Only derived readings cross the boundary — never a raw HealthKit sample.
    var payload: [String: Any] {
        var out: [String: Any] = [:]
        if let v = sedentaryMinutes { out["sedentaryMinutes"] = v }
        if let v = hydrationML { out["hydrationML"] = v }
        if let v = hydrationTargetML { out["hydrationTargetML"] = v }
        if let v = sleepHoursLastNight { out["sleepHoursLastNight"] = v }
        if let v = sleepDebtHours { out["sleepDebtHours"] = v }
        if let v = kilojoulesLogged { out["kilojoulesLogged"] = v }
        if let v = kilojoulesTarget { out["kilojoulesTarget"] = v }
        if let v = minutesSinceLastNudge { out["minutesSinceLastNudge"] = v }
        if let v = inMeeting { out["inMeeting"] = v }
        return out
    }
}
