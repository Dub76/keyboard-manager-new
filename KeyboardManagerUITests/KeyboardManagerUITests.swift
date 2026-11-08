import XCTest

@MainActor
final class KeyboardManagerUITests: XCTestCase {
    func testEnglishPreferenceLocalizesRunningInterface() {
        continueAfterFailure = false
        let app = launchIsolatedApp(language: "en")
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Gallery"].exists)
        XCTAssertTrue(app.staticTexts["Capture"].exists)
        XCTAssertTrue(app.buttons["New board"].exists)
    }

    func testPrimaryNavigationOrderAndDirtyWindowCloseProtection() {
        continueAfterFailure = false
        let app = launchIsolatedApp()
        defer { app.terminate() }

        let overview = app.descendants(matching: .any)["sidebar.overview"]
        let gallery = app.descendants(matching: .any)["sidebar.gallery"]
        let capture = app.descendants(matching: .any)["sidebar.capture"]

        XCTAssertTrue(overview.waitForExistence(timeout: 3))
        XCTAssertTrue(gallery.exists)
        XCTAssertTrue(capture.exists)
        XCTAssertLessThan(overview.frame.minY, gallery.frame.minY)
        XCTAssertLessThan(gallery.frame.minY, capture.frame.minY)

        capture.click()

        let nameField = app.textFields["capture.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        nameField.click()
        nameField.typeText("Ungespeicherter UI-Test")

        let closeButton = app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.exists)
        closeButton.click()

        let closeDialog = app.sheets.firstMatch
        XCTAssertTrue(closeDialog.waitForExistence(timeout: 3))
        let keepEditingButton = closeDialog.buttons["Weiter bearbeiten"]
        XCTAssertTrue(keepEditingButton.waitForExistence(timeout: 3))
        XCTAssertTrue(closeDialog.buttons["Änderungen verwerfen und schließen"].exists)
        keepEditingButton.click()
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertTrue((nameField.value as? String)?.contains("UI-Test") == true)

        closeButton.click()
        XCTAssertTrue(closeDialog.waitForExistence(timeout: 3))
        let discardButton = closeDialog.buttons["Änderungen verwerfen und schließen"]
        XCTAssertTrue(discardButton.waitForExistence(timeout: 3))
        discardButton.click()
        XCTAssertFalse(app.windows.firstMatch.waitForExistence(timeout: 2))
    }

    func testOverviewPassesCoreAccessibilityAudit() throws {
        continueAfterFailure = false
        let app = launchIsolatedApp()
        defer { app.terminate() }

        let windowFrame = app.windows.firstMatch.frame
        try app.performAccessibilityAudit(for: [.sufficientElementDescription]) { issue in
            // Ignore only disabled framework-owned containers that users cannot
            // focus: SwiftUI hosting groups and macOS' legacy Touch Bar surface.
            if let element = issue.element, !element.isEnabled {
                if element.elementType == .group || element.elementType == .touchBar {
                    return true
                }
            }
            if let element = issue.element,
               element.elementType == .group,
               element.frame == windowFrame {
                return true
            }
            XCTFail(
                "\(issue.compactDescription): \(issue.detailedDescription) "
                + "Element: \(String(describing: issue.element))"
            )
            return true
        }
    }

    func testDamagedDatabaseShowsLoadFailureAndStaysUntouched() throws {
        continueAfterFailure = false
        let root = makeIsolatedRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("inventory.sqlite")
        let damaged = Data("not a database".utf8) + Data(repeating: 0xA5, count: 4_096)
        try damaged.write(to: databaseURL)

        let app = launchIsolatedApp(root: root)
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["Bestand konnte nicht geladen werden"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Erneut laden"].exists)

        // A new entry must not open an editor on top of the empty placeholder.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["Bestand konnte nicht geladen werden"].waitForExistence(timeout: 2)
        )

        app.buttons["Erneut laden"].click()
        XCTAssertTrue(
            app.staticTexts["Bestand konnte nicht geladen werden"].waitForExistence(timeout: 3)
        )
        XCTAssertEqual(try Data(contentsOf: databaseURL), damaged)
    }

    func testMigrationDiscoveryUsesIsolatedApplicationSupportRoot() {
        continueAfterFailure = false
        let app = launchIsolatedApp()
        defer { app.terminate() }

        let migration = app.descendants(matching: .any)["sidebar.migration"]
        let data = app.descendants(matching: .any)["sidebar.data"]

        XCTAssertTrue(data.waitForExistence(timeout: 3))
        XCTAssertFalse(migration.exists)
        data.click()
        XCTAssertTrue(migration.waitForExistence(timeout: 3))
        migration.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["migration.discovery.notFound"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["3 bekannte Kandidaten wurden geprüft. ZIP, JSON oder ein anderer Datenordner können weiterhin manuell gewählt werden."].exists)
    }

    private func makeIsolatedRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KeyboardManagerUITests-\(UUID().uuidString)", isDirectory: true)
    }

    private func launchIsolatedApp(language: String? = nil, root: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-preferredLanguage", language ?? "de"]
        app.launchEnvironment["KEYBOARD_MANAGER_UI_TEST_ROOT"] = (root ?? makeIsolatedRoot()).path
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }
}
