//
//  NotifyAIUITests.swift
//  NotifyAIUITests
//

import XCTest

/// Smoke tests of the main flows. The app runs with an isolated in-memory store.
final class NotifyAIUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        return app
    }

    @MainActor
    func testEmptyLibraryOffersToRecord() throws {
        let app = makeApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["Noch keine Notizen"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecordingRequiresConsent() throws {
        let app = makeApp()
        app.launch()
        #if os(iOS)
        app.buttons["Aufnahme starten"].firstMatch.tap()
        #else
        app.buttons["Aufnahme"].firstMatch.click()
        #endif

        let startButton = app.buttons["Aufnahme starten"].firstMatch
        XCTAssertTrue(startButton.waitForExistence(timeout: 5))
        XCTAssertFalse(startButton.isEnabled, "Recording must not start before consent is confirmed.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        let app = makeApp()
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
