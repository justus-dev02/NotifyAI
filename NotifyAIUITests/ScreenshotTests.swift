//
//  ScreenshotTests.swift
//  NotifyAIUITests
//

import XCTest

/// App Store screenshots with English sample notes. Skipped in the normal test run; started by
/// `scripts/screenshots.sh`, which sets `TEST_RUNNER_NOTIFYAI_SCREENSHOTS=1` and exports the
/// attachments as PNG files.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOTIFYAI_SCREENSHOTS"] == "1", "Only for scripts/screenshots.sh")
        continueAfterFailure = false
    }

    #if os(iOS)
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-screenshot-sample-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(row("Q4 Product Roadmap", in: app).waitForExistence(timeout: 10))
        return app
    }

    /// An element whose label starts with `text`; note rows combine title and subtitle.
    @MainActor
    private func row(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// Saves the whole screen, status bar included, as an attachment named after the device.
    @MainActor
    private func capture(_ name: String) {
        // Let animations and the keyboard settle.
        Thread.sleep(forTimeInterval: 1.5)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func openRoadmap(in app: XCUIApplication) {
        row("Q4 Product Roadmap", in: app).tap()
        XCTAssertTrue(row("The team agreed on the Q4 roadmap", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func test1Library() {
        let app = launch()
        if UIDevice.current.userInterfaceIdiom == .pad {
            // The iPad shows list and note side by side; a different note than the summary shot.
            row("Machine Learning – Lecture 5", in: app).tap()
            XCTAssertTrue(row("Gradient descent, learning-rate schedules", in: app).waitForExistence(timeout: 10))
        }
        capture("1-Library")
    }

    @MainActor
    func test2Summary() {
        let app = launch()
        openRoadmap(in: app)
        capture("2-Summary")
    }

    @MainActor
    func test3Transcript() {
        let app = launch()
        openRoadmap(in: app)
        app.buttons["Transcript"].firstMatch.tap()
        XCTAssertTrue(row("Okay, let's get started", in: app).waitForExistence(timeout: 10))
        capture("3-Transcript")
    }

    @MainActor
    func test4Tasks() {
        let app = launch()
        let entry = app.staticTexts["Open Tasks"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(row("Update the roadmap document", in: app).waitForExistence(timeout: 10))
        capture("4-Tasks")
    }

    @MainActor
    func test5Recording() {
        let app = launch()
        app.buttons["Start Recording"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Start Recording"].firstMatch.waitForExistence(timeout: 10))
        capture("5-Recording")
    }
    #endif
}
