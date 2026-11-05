import XCTest

final class MusicIntelligenceToolUITests: XCTestCase {
    @MainActor func testEnvironmentChecksAdvanceWhileMCPIsIdle() throws {
        let files = FileManager.default
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let base = project.appendingPathComponent(".venv")
        try XCTSkipUnless(files.isExecutableFile(atPath: base.appendingPathComponent("bin/python").path),
                          "Run ./script/setup.sh to install the base environment and MCP service.")
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        // Only install the base environment in the fixture: the next row has a known result.
        try files.createSymbolicLink(at: directory.appendingPathComponent(".venv"), withDestinationURL: base)
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["XDG_CACHE_HOME"] = directory.appendingPathComponent("cache").path
        app.launchEnvironment["MIT_WHISPER_MODEL"] = "base"
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launch()
        defer { app.terminate() }

        // Wait for the real server to bind an ephemeral port without sending it a request.
        let log = directory.appendingPathComponent("mcp.log")
        let listening = NSPredicate { _, _ in
            (try? String(contentsOf: log, encoding: .utf8).contains("Uvicorn running on")) == true
        }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: listening, object: nil)], timeout: 20) == .completed
        else { return XCTFail("MCP did not start: " + ((try? String(contentsOf: log, encoding: .utf8)) ?? "no log")) }

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["声学分析、和声与 MCP 依赖已安装"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未找到 .venv-structure/bin/python"].firstMatch.waitForExistence(timeout: 5))
        // The missing checkpoint must advertise its size and publisher before a download.
        let size = Int64(145_262_807).formatted(.byteCount(style: .decimal))
        XCTAssertTrue(app.staticTexts["base.pt · \(size)"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "OpenAI · Whisper").firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "MCP 空闲时的环境检查结果"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }

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
