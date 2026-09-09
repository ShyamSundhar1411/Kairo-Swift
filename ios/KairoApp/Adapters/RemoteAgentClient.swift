import Foundation
import KairoKit

/// Talks to the KairoServer agent orchestrator.
///
/// The app works without it: with no server configured the composition root uses
/// the on-device fakes, which is the configuration the demo runs in.
public struct RemoteAgentClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public enum ClientError: Error, CustomStringConvertible {
        case http(Int, String)
        case malformed(String)
        public var description: String {
            switch self {
            case let .http(code, body): "server returned \(code): \(body)"
            case let .malformed(what): "malformed response: \(what)"
            }
        }
    }

    public func health() async throws -> [String: Any] {
        try await get("/health")
    }

    /// NFR5: only de-identified, derived features cross the boundary — coverage
    /// counts and a budget, never raw HealthKit series and never a health-
    /// sensitive memory.
    public func arbitrate(userID: String, schedule: NudgeSchedule,
                          coverage: DayCoverage, quietHours: Bool) async throws -> [String: Any] {
        var coveragePayload: [String: Any] = [:]
        for d in CoverageDomain.allCases {
            if let m = coverageMetric(coverage, d) {
                coveragePayload[d.rawValue] = ["observed": m.observedCount, "expected": m.expectedCount]
            }
        }
        return try await post("/v1/arbitrate", [
            "userID": userID,
            "dayStart": ISO8601DateFormatter().string(from: schedule.dayStart),
            "dailyBudget": schedule.dailyBudget,
            "spent": schedule.spent,
            "quietHours": quietHours,
            "coverage": coveragePayload,
        ])
    }

    public func screen(_ text: String, locale: String, domain: CoverageDomain?) async throws -> [String: Any] {
        var payload: [String: Any] = ["text": text, "locale": locale]
        if let domain { payload["domain"] = domain.rawValue }
        return try await post("/v1/screen", payload)
    }

    public func annotate(recordID: String, author: String, text: String) async throws {
        _ = try await post("/v1/decision-records/annotate",
                           ["recordID": recordID, "author": author, "text": text])
    }

    // MARK: - Transport

    private func coverageMetric(_ c: DayCoverage, _ d: CoverageDomain) -> CoverageMetric? {
        c.metrics[d]
    }

    private func get(_ path: String) async throws -> [String: Any] {
        try await send(URLRequest(url: baseURL.appendingPathComponent(path)))
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.malformed("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformed("top level is not an object")
        }
        return object
    }
}
