import Foundation
import KairoKit

/// The only file in the app that knows Open Food Facts exists.
///
/// `NutritionRepository` is the boundary; this is the implementation of it, over
/// URLSession. A bundled offline table used to sit behind the same port so the
/// demo could run with the network switched off — it is gone, along with the
/// rest of the fixtures. A lookup that cannot reach Open Food Facts now reports
/// that it could not, which is worse to demo and true.
///
/// WHAT THIS ADAPTER WILL AND WILL NOT DO
///
/// It resolves a figure somebody else published and carries the citation. It
/// never invents one. That distinction shows up in three places:
///
///   * a product with no energy figure throws `.noEnergyPublished` rather than
///     storing a zero, because energy is the one number the app reports and a
///     zero would read as a measurement;
///   * `serving_size` is only believed when it is unambiguously a mass — "30 ml"
///     is not converted to grams, because that needs a density we do not have;
///   * a failed search returns an error, never a nearest guess.
///
/// Open Food Facts is ODbL-licensed, so `attribution` is a licence condition
/// rather than a courtesy, and every request carries a descriptive User-Agent
/// because their API terms ask for one.
public struct OpenFoodFactsRepository: NutritionRepository {
    public let attribution = "Nutrition data from Open Food Facts (openfoodfacts.org), "
        + "made available under the Open Database Licence (ODbL)."

    /// The product endpoint. Verified working, no API key, one product per call.
    private let productBase: URL
    /// The search endpoint, which lives on a different host to the product API.
    ///
    /// This is `search.openfoodfacts.org` on purpose. The documented search
    /// endpoints on `world.openfoodfacts.org` — both `/api/v2/search` and the
    /// legacy `/cgi/search.pl` — were answering with an HTML "Page temporarily
    /// unavailable" page instead of JSON when this was written, and were still
    /// flapping in and out of that state hours later. The search host stayed up
    /// throughout, so it is the one we ask; `json(at:)` still verifies that the
    /// answer is JSON, because neither host is promised to us. Search is a
    /// convenience that is allowed to fail. Barcode lookup is the path the app
    /// leans on, and it is on the host that never wobbled.
    private let searchBase: URL
    private let session: URLSession

    /// Their terms ask for a descriptive User-Agent so they can tell clients
    /// apart and get in touch if one misbehaves.
    private let userAgent = "Kairo/0.1 (ELEC5620 student project)"

    /// Only the fields we use. Asking for the whole product document would pull
    /// tens of kilobytes per scan over a phone connection.
    private let productFields = "product_name,brands,nutriments,serving_size"
    private let searchFields = "code,product_name,brands,serving_size,nutriments"

    /// NFR14: kilojoules are the stored unit. A source that publishes only
    /// kilocalories is converted on the way in, once, here.
    private let kilojoulesPerKilocalorie = 4.184

    public init(session: URLSession = .shared,
                productBase: URL = URL(string: "https://world.openfoodfacts.org")!,
                searchBase: URL = URL(string: "https://search.openfoodfacts.org")!) {
        self.session = session
        self.productBase = productBase
        self.searchBase = searchBase
    }

    public enum RepositoryError: Error, CustomStringConvertible {
        case http(Int)
        /// The endpoint answered with something that is not JSON — in practice an
        /// HTML error page from a service that is temporarily down.
        case notJSON(String)
        case malformed(String)

        public var description: String {
            switch self {
            case let .http(code): "Open Food Facts returned \(code)"
            case let .notJSON(what): "Open Food Facts did not return JSON: \(what)"
            case let .malformed(what): "unreadable response from Open Food Facts: \(what)"
            }
        }
    }

    // MARK: - Lookup

    public func byBarcode(_ code: String) async throws -> FoodReference {
        let barcode = Self.normalisedBarcode(code)
        // A code that is not digits is not a barcode, and it has no business
        // being interpolated into a URL path either.
        guard !barcode.isEmpty else { throw NutritionLookupError.notFound(code) }

        var components = URLComponents(
            url: productBase.appendingPathComponent("api/v2/product/\(barcode).json"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: productFields)]

        // A miss is HTTP 404 carrying `{"status":0}`, so 404 is not a transport
        // failure here — the body is the answer.
        let object = try await json(at: components.url!, timeout: 20, tolerating: [404])
        guard Self.number(object["status"]) == 1,
              let product = object["product"] as? [String: Any] else {
            throw NutritionLookupError.notFound(barcode)
        }
        return try reference(from: product, barcode: barcode)
    }

    /// Text search, which is allowed to come back empty or to fail outright.
    ///
    /// An empty result routes a meal entry to the ungrounded branch, where the
    /// app asks to be taught. That is the intended behaviour: it is better than
    /// offering the user a product that merely sounds similar and letting its
    /// numbers stand in for theirs.
    public func search(_ text: String, limit: Int) async throws -> [FoodReference] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }

        var components = URLComponents(
            url: searchBase.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            // Over-fetch a little: hits with no energy figure are dropped below,
            // and dropping them must not leave the list short.
            URLQueryItem(name: "page_size", value: String(min(50, max(limit * 2, limit + 5)))),
            URLQueryItem(name: "fields", value: searchFields),
        ]

        // The search host answers in about four seconds when it is healthy, so
        // fifteen is a leash rather than a wait: long enough not to fail a slow
        // but working query, short enough that a dead endpoint gives up while
        // the user is still looking at the screen.
        let object = try await json(at: components.url!, timeout: 15)
        guard let hits = object["hits"] as? [[String: Any]] else {
            throw RepositoryError.malformed("search response had no hits array")
        }

        var results: [FoodReference] = []
        for hit in hits {
            guard let code = (hit["code"] as? String) ?? (hit["code"] as? NSNumber)?.stringValue
            else { continue }
            // A hit that publishes no energy is silently skipped rather than
            // patched up with a zero. Skipping is honest; zero is a lie.
            guard let reference = try? reference(from: hit, barcode: code) else { continue }
            results.append(reference)
            if results.count == limit { break }
        }
        return results
    }

    // MARK: - Mapping

    /// One mapper for both endpoints: the search host returns the same
    /// `nutriments` keys as the product host, so the energy rule and the serving
    /// rule cannot drift apart between the two paths.
    private func reference(from product: [String: Any], barcode: String) throws -> FoodReference {
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        let publishedKJ = Self.number(nutriments["energy-kj_100g"])
        let publishedKcal = Self.number(nutriments["energy-kcal_100g"])

        let kilojoules: Double
        if let publishedKJ, publishedKJ >= 0 {
            kilojoules = publishedKJ
        } else if let publishedKcal, publishedKcal >= 0 {
            // Plenty of rows carry only kilocalories, usually because the label
            // they were copied from was not an Australian one.
            kilojoules = publishedKcal * kilojoulesPerKilocalorie
        } else {
            // Missing macros default to zero, which understates a total and is
            // visible as such. A missing energy figure cannot be defaulted: it is
            // the number the app puts on screen.
            throw NutritionLookupError.noEnergyPublished(barcode)
        }

        let brand = Self.brandText(product["brands"])
        let name = Self.text(product["product_name"]) ?? brand
        // A row with neither a name nor a brand cannot be shown to the user
        // honestly — they would be asked to confirm a nameless number.
        guard let name, !name.isEmpty else { throw NutritionLookupError.notFound(barcode) }

        return FoodReference(
            id: "off:\(barcode)",
            name: name,
            brand: brand == name ? nil : brand,
            per100g: NutritionFacts(
                kilojoules: kilojoules,
                proteinGrams: Self.number(nutriments["proteins_100g"]) ?? 0,
                carbGrams: Self.number(nutriments["carbohydrates_100g"]) ?? 0,
                fatGrams: Self.number(nutriments["fat_100g"]) ?? 0),
            declaredServingGrams: Self.servingGrams(Self.text(product["serving_size"])),
            source: "Open Food Facts",
            sourceID: barcode)
    }

    /// Digits only. Open Food Facts codes keep their leading zeros, so this
    /// trims and filters rather than reformatting.
    static func normalisedBarcode(_ code: String) -> String {
        let stripped = code.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        return stripped.allSatisfy(\.isNumber) && !stripped.isEmpty ? stripped : ""
    }

    /// Open Food Facts is crowd-sourced and its numbers arrive as numbers or as
    /// strings depending on who typed them in.
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber:
            return n.doubleValue.isFinite ? n.doubleValue : nil
        case let s as String:
            let value = Double(s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: "."))
            return value?.isFinite == true ? value : nil
        default:
            return nil
        }
    }

    static func text(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The product endpoint returns `brands` as one comma-separated string; the
    /// search host returns it as an array. Both mean the same thing.
    static func brandText(_ any: Any?) -> String? {
        if let list = any as? [String] {
            let joined = list.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }
        return text(any)
    }

    /// Grams out of a free-text serving declaration — and only when it is
    /// unambiguously a mass.
    ///
    /// The field is whatever the contributor typed: "15 g", "30ml", "1 serving
    /// (100 g)", "3/4 cup (28 g)". A volume is never converted, because
    /// millilitres become grams only if you know the density, and getting that
    /// wrong on a drink would be a silent error of tens of per cent.
    static func servingGrams(_ declaration: String?) -> Double? {
        guard let declaration, !declaration.isEmpty else { return nil }
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(kg|mg|grammes|grams|gramme|gram|g|ml|cl|l|litres|litre|oz)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }

        let ns = declaration as NSString
        var grams: [Double] = []
        for match in regex.matches(in: declaration, range: NSRange(location: 0, length: ns.length)) {
            let unit = ns.substring(with: match.range(at: 2)).lowercased()
            guard ["g", "gram", "grams", "gramme", "grammes"].contains(unit),
                  let value = Double(ns.substring(with: match.range(at: 1))
                    .replacingOccurrences(of: ",", with: "."))
            else { continue }
            grams.append(value)
        }
        guard let first = grams.first else { return nil }
        // A declaration that repeats one figure — "3/4 cup (28 g) (28 g)" — is
        // fine. Two different figures mean it is ambiguous, so we take neither.
        guard grams.allSatisfy({ abs($0 - first) < 0.05 }) else { return nil }
        // Sanity bounds: a serving is not zero and not two kilograms.
        guard first > 0, first <= 2_000 else { return nil }
        return first
    }

    // MARK: - Transport

    /// One request, one JSON object, or a clean error. Shaped after
    /// `RemoteAgentClient.send` so both adapters fail the same way.
    private func json(at url: URL, timeout: TimeInterval,
                      tolerating tolerated: Set<Int> = []) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // The port has an `.offline` case precisely so the UI can say "I
            // cannot check right now" instead of showing a number it made up.
            throw Self.isOffline(error) ? NutritionLookupError.offline : error
        }

        guard let http = response as? HTTPURLResponse else {
            throw RepositoryError.malformed("not an HTTP response")
        }

        // Checked before the status code, because an HTML holding page is the
        // more useful diagnosis than whatever status it happened to carry. The
        // first byte is checked as well as the header because the v2 search
        // endpoint was observed serving that HTML page with HTTP 200 *and*
        // `Content-Type: application/json`, so the header cannot be trusted.
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let firstByte = data.first(where: { !" \n\r\t".utf8.contains($0) })
        if contentType.contains("html") || firstByte == UInt8(ascii: "<") {
            throw RepositoryError.notJSON(
                "an HTML page (HTTP \(http.statusCode)) — the service is probably down")
        }
        guard (200..<300).contains(http.statusCode) || tolerated.contains(http.statusCode) else {
            throw RepositoryError.http(http.statusCode)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RepositoryError.malformed("top level is not an object")
        }
        return object
    }

    private static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
             .internationalRoamingOff:
            true
        default:
            false
        }
    }
}
