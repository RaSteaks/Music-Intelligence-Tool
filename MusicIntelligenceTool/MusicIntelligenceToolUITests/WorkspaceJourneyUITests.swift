import XCTest

final class WorkspaceJourneyUITests: XCTestCase {
    @MainActor func testExampleGuideSavesAnAnnotationAndExportsThePreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = makeApp(in: directory)
        app.launch()
        defer { app.terminate() }
        let example = app.buttons["openStudy"]
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        attach(app, name: "打开音频或用示例体验")
        example.click()
        let next = app.buttons["studyNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.click()
        XCTAssertTrue(app.staticTexts["playheadTime"].exists)
        next.click()
        XCTAssertTrue(app.staticTexts["循环试听 · 00:12.00–00:41.80"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "cuePoints").firstMatch.value as? String, "设置选区")
        next.click()
        XCTAssertTrue(app.staticTexts["注释已自动保存。可在右侧修改，或从「导出与分享」查看结果。"].exists)
        attach(app, name: "示例体验添加并保存注释")
        next.click()
        XCTAssertTrue(app.buttons["exportJSON"].waitForExistence(timeout: 5))
        let category = app.popUpButtons["deliveryCategory"]
        category.click()
        app.menuItems["注释 · 1 条"].click()
        XCTAssertTrue(app.staticTexts["听过这段"].exists)
        attach(app, name: "注释与确认状态的交付预览")
        app.buttons["exportJSON"].click()
        let fileName = app.textFields.matching(NSPredicate(format: "value == %@", "Study.analysis.json")).firstMatch
        XCTAssertTrue(fileName.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(directory.path)
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let export = directory.appendingPathComponent("Study.analysis.json")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: export.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 5), .completed)
        let payload = try String(contentsOf: export, encoding: .utf8)
        XCTAssertTrue(payload.contains("听过这段"))
        XCTAssertTrue(payload.contains("\"start\" : 12"))
    }

    @MainActor func testPrepareLyricsReviewInOrderAndFindRemainingWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makeLyricsRuntime(in: directory)
        let audio = directory.appendingPathComponent("New song.wav")
        try FileManager.default.copyItem(at: studyAudioFixture(in: Bundle(for: Self.self)), to: audio)
        let app = makeApp(in: directory)
        app.launchEnvironment["MIT_OPEN_AUDIO"] = audio.path
        app.launch()
        defer { app.terminate() }
        let lyrics = app.buttons["整理歌词"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 10))
        lyrics.click()
        let download = app.buttons["下载测试模型"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["整首歌曲 · 00:00.00–00:48.00"].exists)
        let start = app.buttons["startLocalAnalysis"]
        XCTAssertFalse(start.isEnabled)
        attach(app, name: "整理歌词只准备所需功能")
        download.click()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        start.click()
        let results = app.buttons["viewAnalysisResults"]
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        results.click()
        let first = catalogItem("verse-1", in: app)
        let second = catalogItem("verse-2", in: app)
        let third = catalogItem("verse-3", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["已确认 1/3"].exists)
        first.click()
        let edit = app.links["reviewEdit-label"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.click()
        let input = app.descendants(matching: .any).matching(identifier: "reviewValue-label").firstMatch
        input.typeKey("a", modifierFlags: .command)
        input.typeText("Checked verse")
        XCTAssertFalse(app.buttons["nextRecord"].isEnabled)
        app.buttons["saveAndNextRecord"].click()
        XCTAssertTrue(app.staticTexts["已确认 2/3"].exists)
        XCTAssertTrue(app.staticTexts["选中 Second verse"].exists)
        app.buttons["nextPendingRecord"].click()
        XCTAssertTrue(app.staticTexts["选中 Third verse"].exists)
        app.buttons["previousRecord"].click()
        XCTAssertTrue(app.staticTexts["选中 Second verse"].exists)
        app.buttons["nextRecord"].click()
        app.popUpButtons["catalogFilter"].click()
        app.menuItems["待核对"].click()
        XCTAssertTrue(third.exists)
        XCTAssertFalse(first.exists)
        XCTAssertFalse(second.exists)
        let window = app.windows.firstMatch
        let frame = window.frame
        if frame.width > 880 || frame.height > 600 {
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
            corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: min(0, 880 - frame.width),
                                                                                dy: min(0, 600 - frame.height))))
        }
        XCTAssertTrue(third.isHittable)
        app.popUpButtons["catalogMoreActions"].click()
        XCTAssertTrue(app.menuItems["删除歌词"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        attach(app, name: "窄窗口中的连续校对与待核对筛选")

        app.links["查看所属段落"].click()
        XCTAssertTrue(app.staticTexts["片段概览"].exists)
        let relatedLyrics = app.descendants(matching: .any).matching(identifier: "歌词 · 3 条").firstMatch
        XCTAssertTrue(relatedLyrics.exists)
        let calls = try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertEqual(calls.split(separator: "\n").map(String.init), ["check:lyrics", "download:lyrics", "analysis:lyrics"])
    }

    @MainActor private func makeApp(in directory: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.appendingPathComponent("library").path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launchArguments = ["-reviewAutoAudition", "NO"]
        return app
    }

    @MainActor private func catalogItem(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "catalogItem-" + id).firstMatch
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func makeLyricsRuntime(in directory: URL) throws {
        let files = FileManager.default
        let bin = directory.appendingPathComponent(".venv/bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        // An app cannot execute a script inside the XCTest runner's private container.
        // Link to the bundled fixture, as the environment tests do with the real Python interpreter.
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LyricsTestWorker", withExtension: "sh"))
        try files.createSymbolicLink(at: bin.appendingPathComponent("python"), withDestinationURL: fixture)
        try files.createSymbolicLink(at: bin.appendingPathComponent("ffmpeg"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
    }
}
