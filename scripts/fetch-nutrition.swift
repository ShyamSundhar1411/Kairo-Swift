import Foundation

// Fetches real food composition rows from Open Food Facts and writes
// apps/ios/KairoApp/Resources/nutrition-seed.json.
//
//     swift scripts/fetch-nutrition.swift
//
// WHY THIS SCRIPT EXISTS
//
// The offline demo needs numbers, and the one thing this app must never do is
// present an unverified figure as a measurement — that is the failure the whole
// evidence gate is built to refuse. So nobody hand-types kilojoules from memory
// into this repository. Every row in the seed file is fetched from a published
// source and carries the barcode it came from, so any number on screen can be
// traced back to a row somebody else published:
//
//     https://world.openfoodfacts.org/api/v2/product/<barcode>.json
//
// The list below is a list of CANDIDATES, not a manifest. Open Food Facts is a
// crowd-sourced database: barcodes disappear, products get re-listed, and plenty
// of rows carry macros but no energy at all. The script therefore skips what it
// cannot use, says which and why, and carries on. A run with misses in it is a
// normal run, not a broken one.
//
// Data is licensed under the Open Database Licence (ODbL). Attribution is a
// licence condition, so it is written into the file itself and surfaced by
// NutritionRepository.attribution.
//
// This duplicates a little of OpenFoodFactsRepository's parsing. That is
// deliberate: this is a build-time tool that cannot import the app target, and
// the alternative — putting URLSession into KairoKit to share the code — would
// put the network into the domain layer.

// MARK: - Candidates

/// Foods a student would plausibly log: staples, breakfast, snacks, drinks.
/// Grouped only so a reader can see the coverage; order does not matter because
/// the output is sorted by barcode.
let candidates: [String] = [
    // Staples and fresh
    "9339423001075", // Tip Top 9 Grain Wholemeal bread
    "9300601186945", // Coles Australian Fresh Full Cream Milk
    "9310645356686", // Coles Rolled Oats
    "9300601000562", // Coles Long Grain White Rice
    "9310645178455", // Coles Tuna in Springwater
    "9300633584535", // Woolworths Tuna in Springwater
    "5054268934602", // Tesco Chicken Breast Fillets
    "5201168416138", // Dodoni Authentic Greek Yoghurt 0%
    "9300657009854", // Heinz Baked Beans, cheesy tomato

    // Breakfast
    "9414942010910", // Sanitarium Weet-Bix
    "0016000275270", // Honey Nut Cheerios
    "3229820129488", // Muesli, raisin/fig/date/apricot
    "9300650018860", // Vegemite
    "80177173",      // Nutella, 15 g declared serving
    "3017620422003", // Nutella, 400 g jar
    "9300605126527", // Nestlé Milo

    // Snacks
    "5000159461122", // Snickers
    "0038000138416", // Pringles Original
    "9319133333574", // Carman's Super Berry muesli bar
    "8000500037560", // Kinder Bueno — carries no energy figure; kept on the list
                     // on purpose so the skip path is exercised on every run.

    // Drinks
    "5449000000996", // Coca-Cola
    "5449000131805", // Coca-Cola Zero
    "9300675024235", // Powerade Mountain Blast
    "5000232018700", // Princes Orange Juice

    // Cooked / prepared
    "4897878000012", // Nissin Demae instant noodles
    "8076809513692", // Barilla Napoletana pasta sauce
]

// MARK: - Configuration

/// Their API terms ask for a descriptive User-Agent so they can tell traffic
/// apart and get in touch if a client misbehaves.
let userAgent = "Kairo/0.1 (ELEC5620 student project)"
let source = "Open Food Facts"
let attribution = "Nutrition data from Open Food Facts (openfoodfacts.org), "
    + "made available under the Open Database Licence (ODbL)."
let endpointTemplate = "https://world.openfoodfacts.org/api/v2/product/<barcode>.json"
let fields = "product_name,brands,nutriments,serving_size"

/// A published kilocalorie figure converts at 4.184 kJ/kcal. NFR14: kilojoules
/// are the stored unit; kilocalories are only ever an input or a display.
let kilojoulesPerKilocalorie = 4.184

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let outputURL = repoRoot
    .appendingPathComponent("apps/ios/KairoApp/Resources/nutrition-seed.json")

// MARK: - Fetch

struct Row {
    let barcode: String
    let name: String
    let brand: String?
    let kilojoulesPer100g: Double
    let proteinGramsPer100g: Double
    let carbGramsPer100g: Double
    let fatGramsPer100g: Double
    let declaredServingGrams: Double?
    /// Whether the source published kilojoules or whether we converted its
    /// kilocalories. Recorded so the provenance survives into the file.
    let energyBasis: String
}

enum Skip: Error {
    case notFound
    case noEnergy
    case noName
    case contradictoryEnergy(kj: Double, kcal: Double)
    case transport(String)

    var reason: String {
        switch self {
        case .notFound: "no such product in Open Food Facts"
        case .noEnergy: "product exists but publishes no energy figure"
        case .noName: "product exists but publishes no name or brand"
        case let .contradictoryEnergy(kj, kcal):
            String(format: "published kJ (%.0f) and kcal (%.0f) disagree", kj, kcal)
        case let .transport(what): "request failed: \(what)"
        }
    }
}

func number(_ any: Any?) -> Double? {
    // Open Food Facts is crowd-sourced and its numbers arrive as numbers or as
    // strings depending on who typed them in.
    switch any {
    case let d as Double: return d.isFinite ? d : nil
    case let n as NSNumber: return n.doubleValue.isFinite ? n.doubleValue : nil
    case let s as String: return Double(s.replacingOccurrences(of: ",", with: "."))
    default: return nil
    }
}

/// Grams out of a free-text serving declaration — and only when it is
/// unambiguously grams. "30ml" is not converted, because millilitres become
/// grams only if you know the density, and we do not.
func servingGrams(_ text: String?) -> Double? {
    guard let text, !text.isEmpty else { return nil }
    let pattern = #"(\d+(?:[.,]\d+)?)\s*(kg|mg|grammes|grams|gramme|gram|g|ml|mL|cl|l|litres|litre|oz)\b"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let ns = text as NSString
    var grams: [Double] = []
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let value = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: "."))
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        // Only masses. Every other unit is either a volume — "1 portion
        // (330 ml)" — or something we would have to guess a density for.
        if ["g", "gram", "grams", "gramme", "grammes"].contains(unit), let value {
            grams.append(value)
        }
    }
    guard let first = grams.first else { return nil }
    // "3/4 cup (28 g) (28 g)" repeats itself, which is fine; two *different*
    // gram figures mean the declaration is ambiguous and we take neither.
    guard grams.allSatisfy({ abs($0 - first) < 0.05 }) else { return nil }
    guard first > 0, first <= 2_000 else { return nil }
    return first
}

func fetch(_ barcode: String) async -> Result<Row, Skip> {
    var components = URLComponents(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json")!
    components.queryItems = [URLQueryItem(name: "fields", value: fields)]
    var request = URLRequest(url: components.url!)
    request.timeoutInterval = 30
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    var data = Data()
    // Open Food Facts throttles the product API (their guidance is well under
    // 100 calls a minute) and answers 429 once you cross it. A 429 says "later",
    // not "no such product", so it is retried rather than counted as a miss —
    // otherwise a rate limit would silently shrink the seed file.
    var attempt = 0
    while true {
        attempt += 1
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 429, attempt <= 4 {
                let after = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
                let wait = max(after, Double(attempt) * 15)
                print("        (rate limited, waiting \(Int(wait))s then retrying \(barcode))")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            // A miss comes back as HTTP 404 carrying {"status":0}, so the body is
            // still worth reading; anything else non-2xx is a real transport fault.
            if let http, !(200..<300).contains(http.statusCode), http.statusCode != 404 {
                return .failure(.transport("HTTP \(http.statusCode)"))
            }
            data = body
            break
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure(.transport("response was not JSON"))
    }
    guard number(top["status"]) == 1, let product = top["product"] as? [String: Any] else {
        return .failure(.notFound)
    }

    let nutriments = product["nutriments"] as? [String: Any] ?? [:]
    let publishedKJ = number(nutriments["energy-kj_100g"]).flatMap { $0 > 0 ? $0 : nil }
    let publishedKcal = number(nutriments["energy-kcal_100g"]).flatMap { $0 > 0 ? $0 : nil }

    let kilojoules: Double
    let basis: String
    if let publishedKJ {
        // Both figures published and mutually inconsistent means somebody typed
        // one of them in wrong, and neither is then citable.
        if let publishedKcal {
            let implied = publishedKcal * kilojoulesPerKilocalorie
            if abs(implied - publishedKJ) > max(20, 0.15 * publishedKJ) {
                return .failure(.contradictoryEnergy(kj: publishedKJ, kcal: publishedKcal))
            }
        }
        kilojoules = publishedKJ
        basis = "publishedKilojoules"
    } else if let publishedKcal {
        kilojoules = publishedKcal * kilojoulesPerKilocalorie
        basis = "derivedFromKilocalories"
    } else {
        // Macros without energy are no use: energy is the figure the app reports,
        // and a zero would be a fabricated measurement.
        return .failure(.noEnergy)
    }

    let brands = (product["brands"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let rawName = (product["product_name"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let name = (rawName?.isEmpty == false ? rawName : nil) ?? brands
    guard let name, !name.isEmpty else { return .failure(.noName) }

    return .success(Row(
        barcode: barcode,
        name: name,
        brand: (brands?.isEmpty == false && brands != name) ? brands : nil,
        kilojoulesPer100g: (kilojoules * 100).rounded() / 100,
        proteinGramsPer100g: number(nutriments["proteins_100g"]) ?? 0,
        carbGramsPer100g: number(nutriments["carbohydrates_100g"]) ?? 0,
        fatGramsPer100g: number(nutriments["fat_100g"]) ?? 0,
        declaredServingGrams: servingGrams(product["serving_size"] as? String),
        energyBasis: basis))
}

// MARK: - Run

var rows: [Row] = []
var skipped: [(String, Skip)] = []

print("Fetching \(candidates.count) candidate barcodes from \(source)…\n")
for barcode in candidates {
    switch await fetch(barcode) {
    case let .success(row):
        rows.append(row)
        let serving = row.declaredServingGrams.map { String(format: " · serving %.0f g", $0) } ?? ""
        print(String(format: "  ok    %-14@ %.0f kJ/100 g%@  %@", barcode as NSString,
                     row.kilojoulesPer100g, serving as NSString, row.name as NSString))
    case let .failure(skip):
        skipped.append((barcode, skip))
        print("  skip  \(barcode.padding(toLength: 14, withPad: " ", startingAt: 0)) \(skip.reason)")
    }
    // Be a polite client: their guidance is well under 100 product calls a
    // minute, and this script is not in a hurry.
    try? await Task.sleep(nanoseconds: 1_200_000_000)
}

guard !rows.isEmpty else {
    FileHandle.standardError.write(Data("\nNothing fetched; leaving \(outputURL.lastPathComponent) alone.\n".utf8))
    exit(1)
}

// Sorted by barcode so a re-run produces the same file rather than a reshuffled
// diff, and so the offline repository serves in a stable order.
rows.sort { $0.barcode < $1.barcode }

// The file is written by hand rather than through JSONSerialization because
// JSONSerialization prints a Double at full binary precision — a published 78.57
// comes out as 78.569999999999993 — and a seed file that a marker is expected to
// read against a label should show the figure the label shows. Two decimals is
// already more precision than any nutrition panel carries.
func jsonString(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            out += c.value < 0x20 ? String(format: "\\u%04x", c.value) : String(Character(c))
        }
    }
    return out + "\""
}

func jsonNumber(_ v: Double) -> String {
    let r = (v * 100).rounded() / 100
    if r == r.rounded() { return String(format: "%.0f", r) }
    var s = String(format: "%.2f", r)
    while s.hasSuffix("0") { s.removeLast() }
    return s
}

var lines: [String] = ["{"]
lines.append("  \"source\" : \(jsonString(source)),")
lines.append("  \"attribution\" : \(jsonString(attribution)),")
lines.append("  \"endpoint\" : \(jsonString(endpointTemplate)),")
lines.append("  \"fetchedAt\" : \(jsonString(ISO8601DateFormatter().string(from: Date()))),")
lines.append("  \"generatedBy\" : \"scripts/fetch-nutrition.swift\",")
lines.append("  \"foods\" : [")
for (index, row) in rows.enumerated() {
    var fields: [String] = ["    \"barcode\" : \(jsonString(row.barcode))"]
    fields.append("    \"name\" : \(jsonString(row.name))")
    if let brand = row.brand { fields.append("    \"brand\" : \(jsonString(brand))") }
    fields.append("    \"kilojoulesPer100g\" : \(jsonNumber(row.kilojoulesPer100g))")
    fields.append("    \"proteinGramsPer100g\" : \(jsonNumber(row.proteinGramsPer100g))")
    fields.append("    \"carbGramsPer100g\" : \(jsonNumber(row.carbGramsPer100g))")
    fields.append("    \"fatGramsPer100g\" : \(jsonNumber(row.fatGramsPer100g))")
    if let grams = row.declaredServingGrams {
        fields.append("    \"declaredServingGrams\" : \(jsonNumber(grams))")
    }
    fields.append("    \"energyBasis\" : \(jsonString(row.energyBasis))")
    lines.append("    {")
    lines.append(fields.map { "  " + $0 }.joined(separator: ",\n"))
    lines.append(index == rows.count - 1 ? "    }" : "    },")
}
lines.append("  ]")
lines.append("}")

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
let text = lines.joined(separator: "\n") + "\n"
try Data(text.utf8).write(to: outputURL)

// Cheap self-check: the file we just wrote has to parse, or the app will open on
// an empty larder and nobody will know why until the demo.
guard let reread = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      (reread["foods"] as? [[String: Any]])?.count == rows.count else {
    FileHandle.standardError.write(Data("\nwrote invalid JSON — refusing to claim success\n".utf8))
    exit(1)
}

print("""

wrote \(outputURL.path)
  \(rows.count) row\(rows.count == 1 ? "" : "s") kept, \(skipped.count) skipped of \(candidates.count) candidates
  \(rows.filter { $0.energyBasis == "publishedKilojoules" }.count) with published kilojoules, \
\(rows.filter { $0.energyBasis == "derivedFromKilocalories" }.count) converted from kilocalories
  \(rows.filter { $0.declaredServingGrams != nil }.count) with a declared serving in grams
  energy range \(String(format: "%.1f", rows.map(\.kilojoulesPer100g).min()!))–\(String(format: "%.0f", rows.map(\.kilojoulesPer100g).max()!)) kJ/100 g
""")
if !skipped.isEmpty {
    print("\nskipped:")
    for (barcode, skip) in skipped { print("  \(barcode) — \(skip.reason)") }
}
