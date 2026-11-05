import XCTest

final class TimelineInteractionUITests: XCTestCase {
    @MainActor func testRulerScrubbingAndContinuousOutPoints() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchArguments = ["-cueInShortcut", "i", "-cueOutShortcut", "o"]
        app.launchEnvironment["MIT_LIBRARY"] = directory.path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launch()
        defer { app.terminate() }
        app.buttons["openStudy"].click()
        let waveform = app.descendants(matching: .any).matching(identifier: "waveform").firstMatch
        XCTAssertTrue(waveform.waitForExistence(timeout: 10))
        let ruler = waveform.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: 0, dy: 10))
        let width = waveform.frame.width
        let first = ruler.withOffset(CGVector(dx: width * 0.25, dy: 0))
        let second = ruler.withOffset(CGVector(dx: width * 0.5, dy: 0))
        first.click()
        app.typeKey("o", modifierFlags: [])
        let points = app.descendants(matching: .any).matching(identifier: "cuePoints").firstMatch
        let firstReadout = try XCTUnwrap(points.value as? String)
        XCTAssertTrue(firstReadout.hasPrefix("入 00:00.00   出 "), firstReadout)
        let firstExit = try XCTUnwrap(firstReadout.components(separatedBy: "   出 ").last)
        first.press(forDuration: 0.1, thenDragTo: second)
        XCTAssertEqual(points.value as? String, firstReadout)
        let secondTime = try XCTUnwrap(app.staticTexts["playheadTime"].value as? String)
        let seconds = try XCTUnwrap(Double(secondTime.components(separatedBy: ":").last ?? ""))
        XCTAssertEqual(seconds, 24, accuracy: 0.1)
        app.typeKey("o", modifierFlags: [])
        XCTAssertEqual(points.value as? String, "入 \(firstExit)   出 \(secondTime)")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "时间尺定位与连续出点"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
