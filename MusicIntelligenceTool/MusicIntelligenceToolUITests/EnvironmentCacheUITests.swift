import XCTest

final class EnvironmentCacheUITests: XCTestCase {
    @MainActor func testChecksAreReusedAcrossNavigationAndRelaunchUntilManualRefresh() throws {
        let files = FileManager.default
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = project.appendingPathComponent(".venv")
        try XCTSkipUnless(files.isExecutableFile(atPath: base.appendingPathComponent("bin/python").path),
                          "Run ./script/setup.sh to install the base environment.")
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.appendingPathComponent("library").path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launchEnvironment["XDG_CACHE_HOME"] = directory.appendingPathComponent("cache").path
        app.launchEnvironment["MIT_WHISPER_MODEL"] = "base"
        app.launch()
        defer { app.terminate() }
        openEnvironment(app)
        let original = app.staticTexts["未找到 .venv/bin/python"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        let recheck = app.buttons["重新检查"]
        let idle = NSPredicate { _, _ in recheck.exists && recheck.isEnabled }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: idle, object: nil)], timeout: 10), .completed)
        let savedChecks = directory.appendingPathComponent("library/.environment")
        let savedDirectory = try XCTUnwrap(files.contentsOfDirectory(at: savedChecks, includingPropertiesForKeys: nil).first)
        let savedCheck = savedDirectory.appendingPathComponent("check.json")
        let originalData = try Data(contentsOf: savedCheck)

        // Make the real base environment available after the first check, without downloading any models.
        try files.createSymbolicLink(at: directory.appendingPathComponent(".venv"), withDestinationURL: base)
        app.staticTexts["MCP 服务"].firstMatch.click()
        app.staticTexts["分析环境"].firstMatch.click()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: savedCheck), originalData)
        app.radioButtons["工作区"].click()
        openEnvironment(app)
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: savedCheck), originalData)
        app.terminate()
        app.launch()
        openEnvironment(app)
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: savedCheck), originalData)

        recheck.click()
        XCTAssertTrue(app.staticTexts["声学分析、和声与 MCP 依赖已安装"].waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: idle, object: nil)], timeout: 20), .completed)
        XCTAssertNotEqual(try Data(contentsOf: savedCheck), originalData)
        app.scrollViews.containing(.button, identifier: "重新检查").firstMatch.scroll(byDeltaX: 0, deltaY: -800)
        let lastCheck = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "上次检查：")).firstMatch
        XCTAssertTrue(lastCheck.isHittable)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "环境检查结果复用与手动刷新"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor private func openEnvironment(_ app: XCUIApplication) {
        let settings = app.radioButtons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        let environment = app.staticTexts["分析环境"].firstMatch
        XCTAssertTrue(environment.waitForExistence(timeout: 10))
        environment.click()
    }
}
