//
//  NotifyAIUITests.swift
//  NotifyAIUITests
//

import XCTest

/// Main flows and accessibility audits. The app runs with an isolated in-memory store;
/// `-ui-testing-sample-data` adds two notes with summaries and tasks.
final class NotifyAIUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func makeApp(sampleData: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"] + (sampleData ? ["-ui-testing-sample-data"] : [])
        return app
    }

    @MainActor
    private func tap(_ element: XCUIElement) {
        #if os(iOS)
        element.tap()
        #else
        element.click()
        #endif
    }

    // MARK: - Library and recording

    @MainActor
    func testEmptyLibraryOffersToRecord() throws {
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["Noch keine Notizen"].waitForExistence(timeout: 5))
        // Without tasks there is no task entry in the library.
        XCTAssertFalse(app.staticTexts["Offene Aufgaben"].exists)
    }

    @MainActor
    func testRecordingRequiresConsent() throws {
        let app = makeApp()
        app.launch()
        #if os(iOS)
        tap(app.buttons["Aufnahme starten"].firstMatch)
        #else
        tap(app.buttons["Aufnahme"].firstMatch)
        #endif

        let startButton = app.buttons["Aufnahme starten"].firstMatch
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertFalse(startButton.isEnabled, "Recording must not start before consent is confirmed.")
    }

    // MARK: - Tasks

    @MainActor
    func testTaskOverviewFiltersAndTicksOffTasks() throws {
        let app = makeApp(sampleData: true)
        app.launch()

        let entry = app.staticTexts["Offene Aufgaben"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        tap(entry)

        XCTAssertTrue(task("Präsentation erstellen", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(task("Budget prüfen", in: app).exists)
        XCTAssertTrue(task("Dokumentation aktualisieren", in: app).exists)

        // Filter by person.
        tap(app.buttons["Filter"].firstMatch)
        let anna = app.menuItems["Anna (1)"].firstMatch.exists ? app.menuItems["Anna (1)"].firstMatch : app.buttons["Anna (1)"].firstMatch
        XCTAssertTrue(anna.waitForExistence(timeout: 5))
        tap(anna)
        XCTAssertTrue(task("Präsentation erstellen", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(task("Budget prüfen", in: app).exists)

        // Tick it off: it disappears from the open tasks.
        tap(app.buttons["Als erledigt markieren"].firstMatch)
        let disappeared = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: task("Präsentation erstellen", in: app))
        wait(for: [disappeared], timeout: 5)

        tap(app.buttons["Zurücksetzen"].firstMatch)
        XCTAssertTrue(task("Budget prüfen", in: app).waitForExistence(timeout: 5))
    }

    /// A task row: one button whose label starts with the task.
    @MainActor
    private func task(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    // MARK: - Settings

    @MainActor
    func testSettingsOfferToDeleteDownloadedModels() throws {
        let app = makeApp()
        app.launch()
        #if os(iOS)
        tap(app.buttons["Einstellungen"].firstMatch)
        #else
        app.typeKey(",", modifierFlags: .command)
        #endif
        let button = app.buttons["Geladene Modelle löschen …"].firstMatch
        // The storage section is further down; lists create rows only when they scroll in.
        for _ in 0..<8 where !button.waitForExistence(timeout: 1) {
            #if os(iOS)
            app.swipeUp()
            #else
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -400)
            #endif
        }
        XCTAssertTrue(button.exists)
        // Nothing is downloaded in the test environment.
        XCTAssertFalse(button.isEnabled)
    }

    // MARK: - Accessibility

    @MainActor
    func testAccessibilityOfLibraryAndNote() throws {
        let app = makeApp(sampleData: true)
        app.launch()
        XCTAssertTrue(app.staticTexts["Weekly Marketing"].firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: auditTypes)

        tap(app.staticTexts["Weekly Marketing"].firstMatch)
        XCTAssertTrue(app.staticTexts["Planung der Herbstkampagne."].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: auditTypes)
    }

    @MainActor
    func testAccessibilityOfTaskOverview() throws {
        let app = makeApp(sampleData: true)
        app.launch()
        let entry = app.staticTexts["Offene Aufgaben"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        tap(entry)
        XCTAssertTrue(task("Präsentation erstellen", in: app).waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: auditTypes)
    }

    @MainActor
    func testAccessibilityOfRecordingSetup() throws {
        let app = makeApp()
        app.launch()
        #if os(iOS)
        tap(app.buttons["Aufnahme starten"].firstMatch)
        #else
        tap(app.buttons["Aufnahme"].firstMatch)
        #endif
        XCTAssertTrue(app.buttons["Aufnahme starten"].firstMatch.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: auditTypes)
    }

    /// Everything except checks that concern system-drawn controls outside the app's
    /// influence (contrast of disabled system buttons is reported by the platform itself).
    private var auditTypes: XCUIAccessibilityAuditType {
        #if os(iOS)
        [.dynamicType, .sufficientElementDescription, .hitRegion, .elementDetection, .textClipped, .trait]
        #else
        [.sufficientElementDescription, .elementDetection, .parentChild, .action]
        #endif
    }

    // MARK: - Launch

    @MainActor
    func testLaunchPerformance() throws {
        let app = makeApp()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
