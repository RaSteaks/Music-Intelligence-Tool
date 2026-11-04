import XCTest

final class MusicIntelligenceToolUITests: XCTestCase {
    @MainActor func testOpenStudyEditSharedBoundaryAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "18771"
        app.launch()
        defer { app.terminate() }
        app.buttons["openStudy"].click()
        let end = app.textFields["rangeEnd"]
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        end.click()
        end.typeKey("a", modifierFlags: .command)
        end.typeText("11.50")
        app.buttons["applyRange"].click()
        XCTAssertTrue(app.staticTexts["00:11.50"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.buttons["openStudy"].click()
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertEqual(end.value as? String, "11.500")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "校对后的共享边界"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
