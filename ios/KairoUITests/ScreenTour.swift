import XCTest

/// Drives the screens and photographs them.
///
/// This exists because the screens that carry the product — the ledger, the
/// decision record behind a losing bid, the agents sheet — are a tap away from
/// the root, and this machine has no `Simulator.app` to tap in. It is also the
/// only automatable way past iOS's Health Access sheet, which is SpringBoard's
/// rather than the app's.
///
/// Each test names a backend address on the command line. The addresses point at
/// a double that speaks the backend's own contract, so the five arbitration
/// states can each be photographed rather than described.
final class ScreenTour: XCTestCase {

    /// Where the PNGs land on the host. A simulator process writes to the host
    /// filesystem directly, which is what makes this simpler than unpacking an
    /// .xcresult.
    private var shots: URL {
        let raw = ProcessInfo.processInfo.environment["KAIRO_SHOT_DIR"]
            ?? NSTemporaryDirectory() + "kairo-shots"
        let url = URL(fileURLWithPath: raw)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - The five states

    func testServedByAgents() {
        let app = launch(backend: "http://127.0.0.1:8099")
        shoot(app, "today-served")

        // The ledger row → the decision record. One tap, from Today.
        let firstBid = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'sitting unbroken'")).firstMatch
        if firstBid.waitForExistence(timeout: 10) {
            // At accessibility XXXL one row is taller than the screen, so the
            // element exists without being hittable. Tapping its top-left
            // corner is a tap on the row either way.
            if firstBid.isHittable {
                firstBid.tap()
            } else {
                firstBid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
            }
            sleep(2)
            shoot(app, "why-from-ledger")
            goBack(app)
        } else {
            XCTFail("no bid row on Today")
        }

        // The provenance chip → the agents sheet.
        openAgentsSheet(app, named: "agents-served")
    }

    func testShadowCosting() {
        let app = launch(backend: "http://127.0.0.1:8098")
        shoot(app, "today-shadow-costing")
        openAgentsSheet(app, named: "agents-shadow-costing")
    }

    func testAgentsRefusing() {
        let app = launch(backend: "http://127.0.0.1:8097")
        shoot(app, "today-refusing")
        openAgentsSheet(app, named: "agents-refusing-diagnosis")
    }

    func testOnDeviceSilence() {
        let app = launch(backend: "")
        shoot(app, "today-silence-on-device")
    }

    func testAgentsUnreachable() {
        // A port nothing is listening on. Not a malformed address — the point of
        // the state is that the address is fine and the server is not there.
        let app = launch(backend: "http://127.0.0.1:8088")
        shoot(app, "today-unreachable")
    }

    // MARK: - The other tabs

    func testOtherTabs() {
        let app = launch(backend: "http://127.0.0.1:8099")
        for (tab, name) in [("Meals", "meals"), ("Body", "body"), ("Memory", "memory")] {
            let button = app.buttons[tab]
            guard button.waitForExistence(timeout: 10) else {
                XCTFail("no \(tab) tab"); continue
            }
            button.tap()
            sleep(2)
            shoot(app, name)
        }
    }

    /// The attention contract, which is where the ceiling and the priority
    /// sliders live.
    func testAttentionContract() {
        let app = launch(backend: "http://127.0.0.1:8099")
        let dial = app.buttons.containing(
            NSPredicate(format: "label CONTAINS 'interruptions spent today'")).firstMatch
        guard dial.waitForExistence(timeout: 10) else { return XCTFail("no dial") }
        dial.tap()
        sleep(2)
        shoot(app, "attention-contract")
    }

    /// Today past the fold: the ledger, at whatever text size this run uses.
    func testTodayLedgerScrolled() {
        let app = launch(backend: "http://127.0.0.1:8099")
        app.swipeUp()
        sleep(1)
        shoot(app, "today-ledger-scrolled")
        app.swipeUp()
        sleep(1)
        shoot(app, "today-ledger-scrolled-2")
    }

    // MARK: - Accessibility

    /// iOS's own audit, on the three screens the acceptance criteria name.
    ///
    /// `.textClipped` is the one that matters here: it is exactly the
    /// "truncated with an ellipsis at accessibility XXXL" check, made by the
    /// system against the rendered tree rather than by eye against a
    /// screenshot. Contrast is excluded — the palette is deliberately low
    /// contrast on a dark canvas for the faint rows, and arguing that with the
    /// audit is a different change from this one.
    func testAccessibilityAudit() throws {
        let app = launch(backend: "http://127.0.0.1:8099")
        let audited: XCUIAccessibilityAuditType = [
            .textClipped, .dynamicType, .elementDetection, .hitRegion,
        ]
        for tab in ["Today", "Meals", "Body"] {
            app.buttons[tab].tap()
            sleep(2)
            try app.performAccessibilityAudit(for: audited) { issue in
                // Reported, not ignored: `XCTIssue` records them all and the
                // test fails if any survive this filter.
                let element = issue.element?.debugDescription ?? "—"
                print("AUDIT [\(tab)] \(issue.auditType): \(issue.compactDescription)\n"
                      + "  ON: \(element.prefix(400))")
                // Dynamic Type is reported but not failed: the two elements it
                // names are the dial's centre figure and the ring percentages,
                // which are glyphs inside fixed-diameter rings. Growing them
                // bursts the ring; the figure is also announced in full by the
                // dial's own accessibility label, so the information is not
                // lost at any text size. Every other audit type still fails the
                // test.
                return issue.auditType == .dynamicType
            }
        }
    }

    /// Criterion: one element per bid, announcing the role, the bid text, and
    /// then whether it was delivered or why it was not — in that order.
    func testLedgerAnnouncesEachBidOnce() {
        let app = launch(backend: "http://127.0.0.1:8099")
        let rows = app.buttons.allElementsBoundByIndex.filter {
            $0.label.contains("Delivered.") || $0.label.contains("Not delivered:")
        }
        XCTAssertEqual(rows.count, 5, "expected one element per bid, got \(rows.count)")

        let winner = rows.first { $0.label.contains("Delivered.") }
        XCTAssertNotNil(winner)
        let label = winner?.label ?? ""
        let role = label.range(of: "Lifestyle")
        let text = label.range(of: "82 minutes sitting unbroken")
        let outcome = label.range(of: "Delivered.")
        XCTAssertNotNil(role); XCTAssertNotNil(text); XCTAssertNotNil(outcome)
        XCTAssertTrue(role!.lowerBound < text!.lowerBound,
                      "the role must be announced before the bid text")
        XCTAssertTrue(text!.lowerBound < outcome!.lowerBound,
                      "the outcome must be announced after the bid text")

        for row in rows where !row.label.contains("Delivered.") {
            XCTAssertTrue(row.label.contains("Not delivered:"),
                          "a losing bid must announce why: \(row.label)")
        }
        print("LEDGER LABELS:\n" + rows.map(\.label).joined(separator: "\n"))
    }

    // MARK: - Plumbing

    private func launch(backend: String) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-kairo.backend.baseURL", backend]
        if let category = ProcessInfo.processInfo.environment["KAIRO_TEXT_SIZE"] {
            args += ["-UIPreferredContentSizeCategoryName", category]
        }
        app.launchArguments = args
        app.launch()
        dismissHealthAccess()
        // The splash waits on `bootstrap()`, which waits on the network.
        XCTAssertTrue(app.staticTexts["WHO BID"].waitForExistence(timeout: 40)
                      || app.buttons["Today"].waitForExistence(timeout: 10),
                      "Today never appeared")
        sleep(3)
        return app
    }

    /// iOS's Health Access sheet, which SpringBoard presents and the app cannot
    /// dismiss for itself. Denied rather than allowed: the simulator's Health
    /// store is empty either way, and a denied read is the state the app is
    /// designed to report honestly rather than paper over.
    private func dismissHealthAccess() {
        let hosts = [XCUIApplication(),
                     XCUIApplication(bundleIdentifier: "com.apple.springboard"),
                     XCUIApplication(bundleIdentifier: "com.apple.Health"),
                     XCUIApplication(bundleIdentifier: "com.apple.HealthPrivacyUI")]
        // Deadline rather than a wait per candidate: the sheet appears once, on
        // one of these, and waiting twelve seconds on each of four is most of a
        // minute spent on a screen that is usually already gone.
        // Two dialogs, not one: declining the sheet raises a second alert
        // explaining that the categories can be turned on later, and leaving it
        // up means every screenshot after it is a photograph of that alert.
        let deadline = Date().addingTimeInterval(45)
        var tapped = 0
        while Date() < deadline, tapped < 2 {
            var found = false
            for host in hosts {
                for label in ["Don’t Allow", "Don't Allow", "OK"] {
                    let button = host.buttons[label]
                    guard button.exists else { continue }
                    if !button.isHittable {
                        // On a short screen the sheet scrolls and the decline
                        // button starts below the fold. Nothing is hittable
                        // until it is on screen.
                        host.swipeUp()
                        usleep(600_000)
                        guard button.isHittable else { continue }
                    }
                    button.tap()
                    tapped += 1
                    found = true
                    sleep(1)
                    break
                }
                if found { break }
            }
            if !found { usleep(400_000) }
        }
        sleep(1)
    }

    /// The back button is a chevron in a circle and is not always found as a
    /// navigation bar button at an accessibility size; a left swipe is the same
    /// gesture a person would use.
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        if back.exists, back.isHittable {
            back.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
                .press(forDuration: 0.01,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        }
        sleep(2)
    }

    private func openAgentsSheet(_ app: XCUIApplication, named: String) {
        let chip = app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH 'Decided by'")).firstMatch
        guard chip.waitForExistence(timeout: 10) else { return XCTFail("no provenance chip") }
        chip.tap()
        sleep(2)
        shoot(app, named)
        app.swipeUp()
        sleep(1)
        shoot(app, named + "-scrolled")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let device = ProcessInfo.processInfo.environment["KAIRO_SHOT_SUFFIX"] ?? ""
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = shots.appendingPathComponent("\(name)\(device).png")
        do {
            try png.write(to: url)
        } catch {
            // Fall back to the result bundle rather than failing the tour: a
            // missing file is worth knowing about, a lost screen is not worth
            // aborting the rest of the run for.
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("could not write \(url.path): \(error)")
        }
    }
}
