import XCTest

final class WorkspaceUITests: XCTestCase {
    @MainActor func testEveryCatalogCategoryOffersRecordActions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launch()
        defer { app.terminate() }
        app.buttons["openStudy"].click()
        XCTAssertTrue(app.buttons["加歌词"].waitForExistence(timeout: 10))
        app.terminate()

        // Seed saved records in the isolated library; no models or external services are needed.
        let track = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("analysis.json").path) })
        let file = track.appendingPathComponent("analysis.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let cases = [("lyric", "lyric", "歌词"), ("note", "note", "注释"), ("emotion", "emotion", "情绪"),
                     ("chord", "chord", "和弦"), ("insight", "insight", "解读"), ("loudness", "loudness", "响度"),
                     ("event", "event", "声部活动"), ("rhythm", "tempo", "局部速度"),
                     ("repetition", "repetition", "重复片段"), ("melody", "melody_note", "旋律音符"),
                     ("models", "insight", "解读")]
        let fixtures: [[String: Any]] = cases.map { category, kind, title in
            var fields: [String: Any] = ["label": ["suggested": title]]
            if category == "models" {
                fields["label"] = ["suggested": title, "origin": ["runID": "comparison", "provider": "fixture",
                    "model": "fixture", "evidenceIDs": [], "uncertainty": "", "stale": false]]
            }
            return ["id": "fixture-" + category, "kind": kind, "start": 2, "end": category == "note" ? 2 : 4,
                    "source": "fixture", "startConfirmed": false, "endConfirmed": false, "fields": fields, "metrics": [:]]
        }
        let sections = try XCTUnwrap(record["marks"] as? [[String: Any]])
        record["marks"] = sections + fixtures
        record["cloudBatches"] = [["id": "comparison-batch", "createdAt": 0, "ranges": [["start": 2, "end": 4]],
            "audioSources": [], "maximumRequests": 2, "submittedRequests": 2, "runIDs": ["comparison"], "status": "完成", "mode": "models"]]
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
        app.launch()
        app.buttons["openStudy"].click()
        for (category, _, title) in cases {
            let button = app.buttons["catalogCategory-" + category]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.click()
            let row = app.descendants(matching: .any).matching(identifier: "catalogItem-fixture-" + category).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.rightClick()
            XCTAssertTrue(app.menuItems["定位并校对"].exists)
            XCTAssertEqual(app.menuItems["循环试听"].isEnabled, category != "note")
            if category == "lyric" {
                app.menuItems["定位并校对"].click()
                XCTAssertEqual(app.staticTexts["playheadTime"].value as? String, "00:02.00")
                XCTAssertEqual(app.textFields["rangeStart"].value as? String, "2.000")
                row.rightClick()
                app.menuItems["循环试听"].click()
                let points = app.descendants(matching: .any).matching(identifier: "cuePoints").firstMatch
                XCTAssertEqual(points.value as? String, "入 00:02.00   出 00:04.00")
                app.buttons["播放或暂停"].click()
                row.rightClick()
            }
            let delete = app.menuItems["删除" + title]
            XCTAssertTrue(delete.isEnabled)
            if category == "emotion" {
                let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                screenshot.name = "目录统一右键菜单"; screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            if category == "note" {
                app.typeKey(.escape, modifierFlags: [])
                row.click()
                app.typeKey(.delete, modifierFlags: [])
            } else {
                delete.click()
            }
            XCTAssertFalse(row.exists)
        }
        app.buttons["catalogCategory-section"].click()
        for section in sections.dropLast() {
            let id = try XCTUnwrap(section["id"] as? String)
            app.descendants(matching: .any).matching(identifier: "catalogItem-" + id).firstMatch.rightClick()
            app.menuItems["删除分段"].click()
        }
        let lastID = try XCTUnwrap(sections.last?["id"] as? String)
        app.descendants(matching: .any).matching(identifier: "catalogItem-" + lastID).firstMatch.rightClick()
        XCTAssertFalse(app.menuItems["删除分段"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let marks = try XCTUnwrap(saved["marks"] as? [[String: Any]])
        XCTAssertEqual(marks.compactMap { $0["id"] as? String }, [lastID])
    }

    @MainActor func testLyricContextMenuDeletesClickedRowAndSupportsUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launch()
        defer { app.terminate() }
        app.buttons["openStudy"].click()
        XCTAssertTrue(app.buttons["加歌词"].waitForExistence(timeout: 10))
        app.buttons["加歌词"].click()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalogItem-"))
        XCTAssertEqual(rows.count, 1)
        let firstID = rows.firstMatch.identifier
        app.buttons["加歌词"].click()
        XCTAssertEqual(rows.count, 2)
        let secondID = try XCTUnwrap(rows.allElementsBoundByIndex.first { $0.identifier != firstID }?.identifier)
        let first = app.descendants(matching: .any).matching(identifier: firstID).firstMatch
        let second = app.descendants(matching: .any).matching(identifier: secondID).firstMatch
        second.click()
        // Right-click the unselected row, including the trailing blank part of its hit area.
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).rightClick()
        let delete = app.menuItems["删除歌词"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "歌词右键删除菜单"; screenshot.lifetime = .keepAlways
        add(screenshot)
        delete.click()
        XCTAssertFalse(first.exists)
        XCTAssertTrue(second.exists)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.rightClick()
        app.menuItems["删除歌词"].click()
        app.terminate(); app.launch()
        app.buttons["openStudy"].click()
        XCTAssertTrue(app.buttons["catalogCategory-lyric"].waitForExistence(timeout: 10))
        app.buttons["catalogCategory-lyric"].click()
        XCTAssertFalse(first.exists)
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        second.rightClick()
        app.menuItems["删除歌词"].click()
        XCTAssertTrue(app.staticTexts["还没有记录。用走带条上的按钮添加。"].waitForExistence(timeout: 3))
    }

    @MainActor func testScrubSelectEditAndReopen() throws {
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
        let end = app.textFields["rangeEnd"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.click(); end.typeKey("a", modifierFlags: .command); end.typeText("11.50")
        app.buttons["applyRange"].click()
        XCTAssertTrue(app.staticTexts["00:11.50"].firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.buttons["openStudy"].click()
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertEqual(end.value as? String, "11.500")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "定位、分段校对与重新打开"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
