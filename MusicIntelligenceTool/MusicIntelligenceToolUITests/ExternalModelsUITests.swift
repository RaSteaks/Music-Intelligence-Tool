import XCTest

final class ExternalModelsUITests: XCTestCase {
    @MainActor func testConnectionEditingAndEmptyAnalysisUseIsolatedStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.appendingPathComponent("library").path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launch()
        defer { app.terminate() }
        app.radioButtons["设置"].click()
        app.staticTexts["外部模型"].firstMatch.click()
        let model = app.textFields["cloudModelID"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["新的 API Key"].exists)
        app.buttons["显示密钥"].click()
        XCTAssertTrue(app.textFields["新的 API Key"].exists)
        app.buttons["隐藏密钥"].click()
        model.click(); model.typeText("fixture/audio")
        let save = app.buttons["saveCloudConnection"]
        reveal(save, in: app)
        save.click()
        let file = directory.appendingPathComponent("library/.external-models/connections.json")
        let saved = NSPredicate { _, _ in FileManager.default.fileExists(atPath: file.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: saved, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("fixture/audio"))
        attach(app, name: "外部模型连接保存与能力状态")

        app.terminate(); app.launch()
        app.radioButtons["设置"].click()
        app.staticTexts["外部模型"].firstMatch.click()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "fixture/audio")
        model.click(); model.typeKey("a", modifierFlags: .command); model.typeText("fixture/updated")
        reveal(save, in: app); save.click()
        let updated = NSPredicate { _, _ in (try? String(contentsOf: file, encoding: .utf8).contains("fixture/updated")) == true }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: updated, object: nil)], timeout: 5), .completed)
        let remove = app.buttons["删除此连接及密钥"]
        reveal(remove, in: app); remove.click()
        app.buttons["删除连接及密钥"].click()
        let removed = NSPredicate { _, _ in (try? String(contentsOf: file, encoding: .utf8).contains("fixture/updated")) == false }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 5), .completed)

        app.radioButtons["工作区"].click()
        app.buttons["openStudy"].click()
        let analyze = app.buttons["openCloudAnalysis"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.click()
        XCTAssertTrue(app.staticTexts["请先到设置 → 外部模型添加连接。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["开始分析"].isEnabled)
        attach(app, name: "未配置连接时的云端分析入口")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(analyze.isHittable)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.isHittable { return }
            app.scrollViews.containing(.textField, identifier: "cloudModelID").firstMatch.scroll(byDeltaX: 0, deltaY: -450)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
