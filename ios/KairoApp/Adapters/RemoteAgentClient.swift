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
        public let provider: Provider
        /// Figure 14's four ports and what each is bound to. Architecture facts:
        /// they belong in the agents sheet and nowhere a user would meet them.
        public let ports: [Port]
    }

    /// Which model answered, why that one, and whether the ids it was configured
    /// with actually exist. Enough to tell a working deployment from a
    /// confidently broken one without reading the server's log.
    public struct Provider: Sendable {
        public struct Model: Sendable, Identifiable {
            public let tier: String
            public let id: String
            /// nil when the backend was never able to ask. `false` is the one
            /// that predicts a failure — a model id that does not exist.
            public let validated: Bool?
        }
        public struct Skipped: Sendable, Identifiable {
            public let name: String
            public let displayName: String
            public let reason: String
            public var id: String { name }
        }
        public let name: String
        public let displayName: String
        public let selectedBecause: String
        public let answeredAtBind: Bool?
        public let models: [Model]
        public let supportsTiers: [String]
        /// "metered" or "shadow".
        public let costing: String
        public let considered: [Skipped]

        public var isShadowCosted: Bool { costing == "shadow" }
        /// CF1 — the one provider fact that predicts a failure the user is about
        /// to walk into, so the meal capture prompt can say so before the photo.
        public var visionIsUnavailable: Bool {
            models.first { $0.tier == "vision" }?.validated == false
                || !supportsTiers.contains("vision")
        }
    }

    public struct Port: Sendable, Identifiable {
        public let key: String
        public let interface: String
        public let direction: String
        public let adapter: String
        public let note: String
        public var id: String { key }
    }

    /// The backend answered 503: it is up, and it has said in English what is
    /// wrong. *Unreachable* means check the address; this means read the
    /// sentence. Thrown rather than returned so the one caller that can show it
    /// cannot forget to.
    public struct Refusal: Error, LocalizedError, Sendable {
        /// `diagnosis` when the payload carries one — nothing was bound at all —
        /// and the backend's own `mode` line when a named provider was bound and
        /// answered nothing at bind time, which is the other way to get a 503.
        public let diagnosis: String
        public let provider: Provider?
        public var errorDescription: String? { diagnosis }
    }

    public func health() async throws -> Health {
        let (json, status) = try await sendAllowingRefusal(request(for: "health"))
        let provider = Self.provider(json["provider"] as? [String: Any])
        guard status != 503 else {
            throw Refusal(diagnosis: Self.diagnosis(in: json), provider: provider)
        }
        return Health(mode: json["mode"] as? String ?? "unknown",
                      promptVersion: json["promptVersion"] as? String ?? "unknown",
                      roles: json["roles"] as? [String] ?? [],
                      runtime: json["runtime"] as? String ?? "unknown",
                      provider: provider,
                      ports: Self.ports(json["ports"] as? [String: Any]))
    }

    /// The sentence to print. `diagnosis` is only present on the payload the
    /// refusing app serves — the one that comes up when no provider could be
    /// bound at all. A backend that bound a named provider which then answered
    /// nothing also returns 503, and puts the same kind of sentence in `mode`.
    /// Printing whichever one exists is what makes the Today chip's "agents
    /// refusing" lead somewhere rather than to an empty row.
    private static func diagnosis(in json: [String: Any]) -> String {
        if let d = json["diagnosis"] as? String, !d.isEmpty { return d }
        if let mode = json["mode"] as? String, !mode.isEmpty { return mode }
        return "The backend answered 503 without saying why."
    }

    private static func provider(_ raw: [String: Any]?) -> Provider {
        guard let raw else {
            return Provider(name: "none", displayName: "none", selectedBecause: "",
                            answeredAtBind: nil, models: [], supportsTiers: [],
                            costing: "metered", considered: [])
        }
        // Ordered by the ladder rather than by dictionary order, so the fast
        // tier that does the bidding is always the first row on the sheet.
        let order = ["fast", "deep", "vision"]
        let models = (raw["models"] as? [String: Any] ?? [:])
            .compactMap { tier, value -> Provider.Model? in
                guard let m = value as? [String: Any], let id = m["id"] as? String else { return nil }
                return Provider.Model(tier: tier, id: id, validated: m["validated"] as? Bool)
            }
            .sorted { (order.firstIndex(of: $0.tier) ?? 9) < (order.firstIndex(of: $1.tier) ?? 9) }
        return Provider(
            name: raw["name"] as? String ?? "unknown",
            displayName: raw["displayName"] as? String ?? raw["name"] as? String ?? "unknown",
            selectedBecause: raw["selectedBecause"] as? String ?? "",
            answeredAtBind: raw["answeredAtBind"] as? Bool,
            models: models,
            supportsTiers: raw["supportsTiers"] as? [String] ?? [],
            costing: raw["costing"] as? String ?? "metered",
            considered: (raw["considered"] as? [[String: Any]] ?? []).compactMap {
                guard let name = $0["name"] as? String else { return nil }
                return Provider.Skipped(name: name,
                                        displayName: $0["displayName"] as? String ?? name,
                                        reason: $0["reason"] as? String ?? "")
            })
    }

    private static func ports(_ raw: [String: Any]?) -> [Port] {
        let order = ["pLLM", "pHealth", "pEvents", "pNotify"]
        return (raw ?? [:]).compactMap { key, value -> Port? in
            guard let p = value as? [String: Any] else { return nil }
            return Port(key: key,
                        interface: p["interface"] as? String ?? "",
                        direction: p["direction"] as? String ?? "",
                        adapter: p["adapter"] as? String ?? "",
                        note: p["note"] as? String ?? "")
        }
        .sorted { (order.firstIndex(of: $0.key) ?? 9) < (order.firstIndex(of: $1.key) ?? 9) }
    }

    // MARK: - Section 7.1, the second budget

    /// The cost ladder, in the backend's own words.
    ///
    /// `note` is served as a finished sentence and is rendered verbatim: the one
    /// place in the app that is allowed to show the money is also the one place
    /// that must not paraphrase what the money means.
    public struct Budget: Sendable {
        public let tier: String
        public let costing: String
        public let notional: Bool
        public let note: String
        public let spentHundredthsOfACent: Int
        public let ceilingHundredthsOfACent: Int

        public var isNotional: Bool { notional || costing == "shadow" }
    }

    public func budget(userID: String) async throws -> Budget {
        let json = try await send(request(for: "v1/budget", query: ["userID": userID]))
        return Budget(tier: json["tier"] as? String ?? "unknown",
                      costing: json["costing"] as? String ?? "metered",
                      notional: json["notional"] as? Bool ?? false,
                      note: json["note"] as? String ?? "",
                      spentHundredthsOfACent: json["spentHundredthsOfACent"] as? Int ?? 0,
                      ceilingHundredthsOfACent: json["ceilingHundredthsOfACent"] as? Int ?? 0)
    }

    // MARK: - CF9

    /// The contract the agents are already holding for this user.
    ///
    /// A read, not a proposal. The app has no calendar, no thermometer and no
    /// time-zone watcher, so it has no disruption signal to offer
    /// `/v1/contract/evaluate` that it would not have had to invent — and a
    /// fabricated signal is the one thing CF9's corroboration rule exists to
    /// refuse. What it can honestly do is ask what the roles concluded from the
    /// evidence they have, and put a `proposed` contract in front of the user.
    public struct RemoteContract: Sendable {
        public let id: String
        public let state: String
        public let kind: String?
        public let targetReduction: Double
        public let suspendedClasses: [String]
        public let expiresAt: Date?
        public let signalSources: [String]
        /// FR9.5. Set only when the Steward refused, which is the one case
        /// where a contract arrives in `standard` with something to say.
        public let stewardVetoReason: String?
    }

    public func contract(userID: String) async throws -> RemoteContract? {
        let json = try await send(request(for: "v1/contract", query: ["userID": userID]))
        return Self.contract(json["contract"] as? [String: Any])
    }

    /// CF9 — consent, recorded where the agents can see it. Without this the
    /// accept button moved a copy of the contract on the phone and the backend
    /// kept proposing the same one on the next pass.
    public func respondToContract(userID: String, accept: Bool) async throws -> RemoteContract? {
        let json = try await send(request(for: "v1/contract/respond",
                                          body: ["userID": userID, "accept": accept]))
        return Self.contract(json["contract"] as? [String: Any])
    }

    private static func contract(_ raw: [String: Any]?) -> RemoteContract? {
        guard let raw, let id = raw["id"] as? String,
              let state = raw["state"] as? String else { return nil }
        return RemoteContract(
            id: id, state: state, kind: raw["kind"] as? String,
            targetReduction: raw["targetReduction"] as? Double ?? 0,
            suspendedClasses: raw["suspendedClasses"] as? [String] ?? [],
            expiresAt: (raw["expiresAt"] as? String).flatMap(parse(instant:)),
            signalSources: raw["signalSources"] as? [String] ?? [],
            stewardVetoReason: raw["stewardVetoReason"] as? String)
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
        /// What each role actually said, not merely that it spoke.
        ///
        /// This used to be `[String]` — `fragments.map { $0["agent"] }` — and the
        /// claim, the prompt version and the confidence on the same object were
        /// dropped on the floor. `WhyView`'s role timeline, which is the best
        /// thing in the app, then drew five rows of empty text at 100% confident
        /// every time the backend served the pass. The data was always on the
        /// wire.
        public let contributions: [Contribution]
        public let citedMemories: [(id: String, confidence: Double)]
        public let serviceTier: String
        public let safetyVerdict: String?
        /// S7 — which backend produced *this* record, read off the sealed
        /// artefact rather than off whatever is bound right now.
        public let provider: String?
        /// Caveat worth keeping in the type's name rather than in a comment on
        /// one screen: this is the FAST-tier model, the one that does the
        /// bidding, not whichever tier any given sentence was written by.
        public let biddingModelID: String?
        /// Section 7.1, arriving on every pass. Whether the ceiling that
        /// suppressed something stands for a bill or for a stand-in.
        public let costing: String
        public let costIsNotional: Bool

        public var contributingRoles: [String] { contributions.map(\.agentID) }
    }

    public struct Contribution: Sendable {
        public let agentID: String
        public let promptVersion: String
        public let claim: String
        public let confidence: Double
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
                          quietHours: Bool, profile: CapabilityProfile,
                          priorities: [String: Double] = [:]) async throws -> Arbitration {
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
            // OF3. The roles bid against the same weights the contract screen
            // shows, so the slider is not a setting the agents never hear about.
            "priorities": priorities,
        ]))

        let record = json["record"] as? [String: Any] ?? [:]
        let budget = json["budget"] as? [String: Any] ?? [:]
        return Arbitration(
            delivered: (json["delivered"] as? [[String: Any]] ?? []).compactMap(Self.nudge),
            suppressed: (json["suppressed"] as? [[String: Any]] ?? []).compactMap(Self.nudge),
            spent: json["spent"] as? Int ?? schedule.spent,
            spentNothing: json["spentNothing"] as? Bool ?? true,
            recordID: record["id"] as? String ?? "",
            contributions: (record["fragments"] as? [[String: Any]] ?? []).compactMap {
                guard let agent = $0["agent"] as? String else { return nil }
                return Contribution(
                    agentID: agent,
                    promptVersion: $0["promptVersion"] as? String ?? "unknown",
                    claim: $0["claim"] as? String ?? "",
                    // Not 1. A missing confidence is unknown, and drawing an
                    // unknown as full certainty is the failure this whole app
                    // argues against.
                    confidence: $0["confidence"] as? Double ?? 0)
            },
            citedMemories: (record["citations"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["memoryID"] as? String else { return nil }
                return (id, $0["confidenceAtCitation"] as? Double ?? 0)
            },
            serviceTier: json["serviceTier"] as? String ?? "unknown",
            safetyVerdict: record["safetyVerdict"] as? String,
            provider: record["provider"] as? String,
            biddingModelID: record["modelID"] as? String,
            costing: budget["costing"] as? String ?? "metered",
            costIsNotional: budget["notional"] as? Bool ?? false)
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

    /// CF7 — report what the user did with an interruption this service allocated.
    ///
    /// Sent as well as stored locally, not instead: the phone's log is what the
    /// on-device arbiter learns from when this service is unreachable, and the
    /// service's is what the roles reason with. Reporting only locally would mean
    /// the agents kept bidding into a class the user had dismissed twenty times.
    ///
    /// The instant carries this phone's offset, for the reason `instant` explains:
    /// the hour of the user's day is what the model learns from, and letting the
    /// server stamp it would file a Sydney afternoon under the region's hour.
    public func report(outcome: NudgeOutcome, userID: String) async throws {
        _ = try await send(request(for: "v1/nudges/outcome", body: [
            "userID": userID,
            "nudgeClass": outcome.nudgeClass,
            "response": outcome.response.rawValue,
            "at": Self.instant.string(from: outcome.at),
        ]))
    }

    /// The memory book the agents actually retrieve from.
    ///
    /// The app used to render a locally seeded list here, which meant the
    /// Memory Book screen and the memories the roles reasoned over were two
    /// different sets of facts that happened to look alike. Forgetting one on
    /// the server left it on screen, and a fact extracted on the server never
    /// appeared at all.
    ///
    /// States are replayed through `MemoryItemState` rather than assigned, so a
    /// state this app's machine does not declare is dropped instead of shown.
    public func memoryBook(at now: Date) async throws -> [MemoryItem] {
        let json = try await send(request(for: "v1/memories/book"))
        return (json["memories"] as? [[String: Any]] ?? []).compactMap {
            Self.memory($0, at: now)
        }
    }

    /// CF10: forgetting has to happen where the agents read from, or the fact
    /// stays in every answer they give while the screen says it is gone.
    public func forget(memoryID: String) async throws {
        _ = try await send(request(for: "v1/memories/\(memoryID)", method: "DELETE"))
    }

    static func memory(_ raw: [String: Any], at now: Date) -> MemoryItem? {
        guard let id = raw["id"] as? String,
              let text = raw["text"] as? String,
              let stateName = raw["state"] as? String,
              let state = MemoryItemState(rawValue: stateName),
              let lifecycle = Lifecycle<MemoryItemState>.replaying(to: state, at: now)
        else { return nil }

        var item = MemoryItem(
            id: id,
            text: text,
            confidence: raw["confidence"] as? Double ?? 0,
            sensitivity: (raw["sensitivity"] as? String)
                .flatMap(MemorySensitivity.init(rawValue:)) ?? .ordinary,
            sourceRef: raw["sourceRef"] as? String ?? "agents",
            decayExempt: raw["decayExempt"] as? Bool ?? false)
        item.lifecycle = lifecycle
        for recordID in raw["pinnedBy"] as? [String] ?? [] { item.pin(by: recordID) }
        return item
    }

    public func annotate(recordID: String, author: String, text: String) async throws {
        _ = try await send(request(for: "v1/decision-records/annotate",
                                   body: ["recordID": recordID, "author": author, "text": text]))
    }

    // MARK: - Transport

    private func request(for path: String, query: [String: String] = [:],
                         body: [String: Any]? = nil,
                         method: String? = nil) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        if let method { request.httpMethod = method }
        if let body {
            request.httpMethod = method ?? "POST"
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
    static let instant: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// Accepts the ISO instants the backend emits, which carry fractional
    /// seconds where `datetime.isoformat()` has a microsecond component.
    static let instantWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    static func parse(instant raw: String) -> Date? {
        instantWithFraction.date(from: raw) ?? instant.date(from: raw)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (object, status) = try await sendAllowingRefusal(request)
        guard (200..<300).contains(status) else {
            // A 503 from a route other than /health is the refusing app saying
            // the same thing /health says; carry its sentence rather than the
            // JSON body, so whatever surfaces the error has something to print.
            if status == 503 {
                throw Refusal(diagnosis: Self.diagnosis(in: object),
                              provider: Self.provider(object["provider"] as? [String: Any]))
            }
            throw ClientError.http(status, String(describing: object))
        }
        return object
    }

    /// 503 is a real answer here, not a transport failure: the backend is up and
    /// has told the client in English what is misconfigured. Swallowing it into
    /// `unreachable` throws away the most useful sentence the server can send.
    private func sendAllowingRefusal(_ request: URLRequest) async throws -> ([String: Any], Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformed("not an HTTP response")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard (200..<300).contains(http.statusCode) else {
                throw ClientError.http(http.statusCode,
                                       String(data: data, encoding: .utf8) ?? "")
            }
            throw ClientError.malformed("top level is not an object")
        }
        return (object, http.statusCode)
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
