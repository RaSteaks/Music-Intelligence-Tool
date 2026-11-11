import XCTest

final class AudioDropUITests: XCTestCase {
    @MainActor func testFinderDropsOpenAudioInEmptyAndLoadedWorkspace() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("AudioDrop-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: directory) }
        let study = try studyAudioFixture(in: Bundle(for: Self.self))
        for name in ["drop-first.wav", "drop-second.wav"] {
            try files.copyItem(at: study, to: directory.appendingPathComponent(name))
        }
        let app = XCUIApplication()
        app.launchEnvironment["MIT_LIBRARY"] = directory.appendingPathComponent("library").path
        app.launchEnvironment["MIT_RUNTIME"] = directory.path
        app.launchEnvironment["MIT_MCP_PORT"] = "0"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["openStudy"].waitForExistence(timeout: 10))

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        finder.typeKey("n", modifierFlags: .command)
        defer {
            finder.activate()
            finder.typeKey("w", modifierFlags: .command)
        }
        finder.typeKey("g", modifierFlags: [.command, .shift])
        finder.typeText(directory.path)
        finder.typeKey(.return, modifierFlags: [])
        finder.typeKey("2", modifierFlags: .command)
        let finderWindow = finder.windows.firstMatch
        let frame = finderWindow.frame
        if frame.width > 620 || frame.height > 440 {
            let corner = finderWindow.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: min(0, 600 - frame.width),
                                                                                dy: min(0, 420 - frame.height))))
        }

        for name in ["drop-first", "drop-second"] {
            finder.activate()
            let source = finderWindow.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 10))
            // Keep the drop point outside the new Finder window so the workspace receives the native drag.
            let window = app.windows.firstMatch
            let points = [CGVector(dx: 0.95, dy: 0.9), CGVector(dx: 0.05, dy: 0.9),
                          CGVector(dx: 0.95, dy: 0.3), CGVector(dx: 0.05, dy: 0.3)]
            let target = try XCTUnwrap(points.first { offset in
                let point = CGPoint(x: window.frame.minX + window.frame.width * offset.dx,
                                    y: window.frame.minY + window.frame.height * offset.dy)
                return !finderWindow.frame.insetBy(dx: -8, dy: -8).contains(point)
            })
            source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: target))
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10))
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "waveform").firstMatch.exists)
        }
        app.activate()
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "从 Finder 拖入并切换音频"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

func studyAudioFixture(in testBundle: Bundle) throws -> URL {
    // Read the same built-in sample from the build products, avoiding Desktop access from the runner.
    let products = testBundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let app = Bundle(url: products.appendingPathComponent("MusicIntelligenceTool.app"))
    return try XCTUnwrap(app?.url(forResource: "Study", withExtension: "wav"))
}
