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

    /// An element whose label starts with `text`, whatever its kind. Note rows combine title
    /// and subtitle into one element, and selectable texts are text views on the Mac.
    @MainActor
    private func element(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", text, text)).firstMatch
    }

    /// A button of the confirmation dialog on screen (on the Mac not the Touch Bar's copy).
    @MainActor
    private func dialogButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        #if os(iOS)
        app.buttons[title].firstMatch
        #else
        app.sheets.buttons[title].exists ? app.sheets.buttons[title].firstMatch : app.dialogs.buttons[title].firstMatch
        #endif
    }

    /// A toolbar menu: a menu button on the Mac, a button on iOS.
    @MainActor
    private func toolbarMenu(_ title: String, in app: XCUIApplication) -> XCUIElement {
        #if os(iOS)
        app.buttons[title].firstMatch
        #else
        app.menuButtons[title].firstMatch
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
        tap(toolbarMenu("Aufgaben filtern", in: app))
        #if os(macOS)
        // On the Mac the person picker is a submenu of the filter menu.
        let person = app.menuItems["Person"].firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 5))
        tap(person)
        let anna = app.menuItems["Anna (1)"].firstMatch
        #else
        let anna = app.buttons["Anna (1)"].firstMatch
        #endif
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
        // Whisper models live in the test's own folder, but Apple Speech reserves its language
        // packs for the app system-wide. Whatever is there, the button offers the deletion
        // with a confirmation, which is cancelled here.
        guard button.isEnabled else { return }
        tap(button)
        let cancel = dialogButton("Abbrechen", in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        tap(cancel)
    }

    // MARK: - Accessibility

    @MainActor
    func testAccessibilityOfLibraryAndNote() throws {
        let app = makeApp(sampleData: true)
        app.launch()
        let row = element("Weekly Marketing", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        try audit(app)

        tap(row)
        XCTAssertTrue(element("Planung der Herbstkampagne.", in: app).waitForExistence(timeout: 5))
        try audit(app)
    }

    @MainActor
    func testAccessibilityOfTaskOverview() throws {
        let app = makeApp(sampleData: true)
        app.launch()
        let entry = app.staticTexts["Offene Aufgaben"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        tap(entry)
        XCTAssertTrue(task("Präsentation erstellen", in: app).waitForExistence(timeout: 5))
        try audit(app)
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
        try audit(app)
    }

    /// Audits the visible screen. Every issue of the app's own views fails the test. Issues of
    /// what AppKit draws and exposes itself are ignored (all of them were checked by hand):
    /// - Elements outside the app's window: the menu bar and its status items.
    /// - SwiftUI's hosting groups on the Mac (the window's content area, a toolbar row): they
    ///   have neither label nor identifier and are not part of the app's views.
    /// - "Action is missing" on pop-up and menu buttons: AppKit opens pickers and toolbar menus
    ///   with "show menu", which VoiceOver uses, instead of "press".
    /// - The toolbar's overflow button ("Weitere Objekte in der Symbolleiste"): AppKit's own
    ///   pop-up without an identifier; every control the app puts into the toolbar has one.
    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        let window = app.windows.firstMatch.frame
        let toolbar = app.toolbars.firstMatch
        let toolbarFrame = toolbar.exists ? toolbar.frame : .zero
        try app.performAccessibilityAudit(for: auditTypes) { issue in
            guard let element = issue.element else { return true }
            let isOutsideWindow = !window.contains(element.frame)
            let isHostingGroup = element.elementType == .group && element.label.isEmpty && element.identifier.isEmpty
            let isMenuOpener = issue.auditType == .action && [.popUpButton, .menuButton].contains(element.elementType)
            let isToolbarOverflow = element.elementType == .popUpButton && element.identifier.isEmpty
                && toolbarFrame.contains(element.frame)
            return isOutsideWindow || isHostingGroup || isMenuOpener || isToolbarOverflow
        }
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
