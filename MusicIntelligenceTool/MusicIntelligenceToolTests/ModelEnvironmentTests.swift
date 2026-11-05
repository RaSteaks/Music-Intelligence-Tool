import Foundation
import Testing
@testable import MusicIntelligenceTool

@MainActor
struct ModelEnvironmentTests {
    @Test func completedChecksSurviveReopeningUntilExplicitRefresh() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let models = fixture.makeEnvironment()
        models.checkIfNeeded()
        try await finish(models)
        let checkedAt = try #require(models.checkedAt)
        let ffmpeg = models.ffmpeg
        #expect(models.cacheError == nil)
        #expect(try fixture.calls().count == ModelFeature.allCases.count)

        try fixture.writeReport("新的环境状态")
        models.checkIfNeeded()
        #expect(!models.isBusy)
        #expect(models.reports[.base]?.detail == "首次检查结果")

        let reopened = fixture.makeEnvironment()
        reopened.checkIfNeeded()
        #expect(!reopened.isBusy)
        #expect(reopened.checkedAt == checkedAt)
        #expect(reopened.ffmpeg == ffmpeg)
        #expect(reopened.reports.count == ModelFeature.allCases.count)
        #expect(reopened.reports[.lyrics]?.weights?.first?.name == "model.bin")
        #expect(reopened.reports[.lyrics]?.weights?.first?.bytes == 128)
        #expect(reopened.reports[.lyrics]?.weights?.first?.url?.host == "example.invalid")
        #expect(try fixture.calls().count == ModelFeature.allCases.count)

        reopened.refresh()
        try await finish(reopened)
        #expect(reopened.reports[.base]?.detail == "新的环境状态")
        #expect(try fixture.calls().count == ModelFeature.allCases.count * 2)
        #expect(fixture.makeEnvironment().reports[.base]?.detail == "新的环境状态")
    }

    @Test func runtimeDirectoriesKeepSeparateSavedChecks() async throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        try second.writeReport("第二个运行目录")
        let models = first.makeEnvironment()
        models.checkIfNeeded()
        try await finish(models)
        models.checkIfNeeded(in: second.runtime)
        try await finish(models)
        #expect(models.directory == second.runtime)
        #expect(models.reports[.base]?.detail == "第二个运行目录")
        models.checkIfNeeded(in: first.runtime)
        #expect(!models.isBusy)
        #expect(models.reports[.base]?.detail == "首次检查结果")
        #expect(try first.calls().count == ModelFeature.allCases.count)
        #expect(try second.calls().count == ModelFeature.allCases.count)
    }

    @Test func failedChecksAreSavedUntilUserRetries() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("{\"error\":\"fixture failure\"}\n".utf8).write(to: fixture.runtime.appendingPathComponent("check.json"))
        let models = fixture.makeEnvironment()
        models.checkIfNeeded()
        try await finish(models)
        #expect(models.reports[.base]?.state == .blocked)
        #expect(models.errors[.base]?.contains("fixture failure") == true)

        let reopened = fixture.makeEnvironment()
        reopened.checkIfNeeded()
        #expect(!reopened.isBusy)
        #expect(reopened.errors[.base] == models.errors[.base])
        #expect(try fixture.calls().count == ModelFeature.allCases.count)
        try fixture.writeReport("检查已恢复")
        reopened.refresh()
        try await finish(reopened)
        #expect(reopened.errors.isEmpty)
        #expect(reopened.reports[.base]?.detail == "检查已恢复")
    }

    @Test func downloadingUpdatesOnlyItsSavedFeature() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let models = fixture.makeEnvironment()
        models.checkIfNeeded()
        try await finish(models)
        let checkedAt = models.checkedAt
        models.download(.lyrics)
        try await finish(models)
        #expect(models.reports[.lyrics]?.state == .ready)
        #expect(models.reports[.base]?.state == .missing)
        #expect(models.checkedAt == checkedAt)
        #expect(try fixture.calls().last == "download:lyrics")
        #expect(try fixture.calls().count == ModelFeature.allCases.count + 1)
        let reopened = fixture.makeEnvironment()
        reopened.checkIfNeeded()
        #expect(!reopened.isBusy)
        #expect(reopened.reports[.lyrics]?.detail == "模型下载完成")
    }

    @Test func cancelledChecksPreserveLastCompleteSnapshot() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let models = fixture.makeEnvironment()
        models.checkIfNeeded()
        try await finish(models)
        let checkedAt = models.checkedAt
        try fixture.writeReport("未完成的新检查")
        try Data().write(to: fixture.runtime.appendingPathComponent("pause"))
        models.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while models.progress != "fixture running", models.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(models.progress == "fixture running")
        models.cancel()
        try await finish(models)
        let reopened = fixture.makeEnvironment()
        #expect(reopened.checkedAt == checkedAt)
        #expect(reopened.reports[.base]?.detail == "首次检查结果")
    }

    @Test func unreadableSavedDataTriggersOneFreshCheck() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let models = fixture.makeEnvironment()
        models.checkIfNeeded()
        try await finish(models)
        let directory = try #require(FileManager.default.contentsOfDirectory(at: fixture.cache,
                                                                            includingPropertiesForKeys: nil).first)
        try Data("invalid saved data".utf8).write(to: directory.appendingPathComponent("check.json"))
        let reopened = fixture.makeEnvironment()
        #expect(reopened.checkedAt == nil)
        reopened.checkIfNeeded()
        try await finish(reopened)
        reopened.checkIfNeeded()
        #expect(!reopened.isBusy)
        #expect(try fixture.calls().count == ModelFeature.allCases.count * 2)
    }

    private func finish(_ models: ModelEnvironment) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while models.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!models.isBusy)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var runtime: URL { root.appendingPathComponent("runtime") }
        var cache: URL { root.appendingPathComponent("saved-checks") }

        init() throws {
            for environment in Set(ModelFeature.allCases.map(\.environment)) {
                let bin = runtime.appendingPathComponent(environment + "/bin")
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                let python = bin.appendingPathComponent("python")
                // Only the external model worker is faked; process streaming and persistence run unchanged.
                let script = """
                #!/bin/sh
                printf '%s:%s\\n' "$2" "$3" >> "$4/calls.log"
                if [ -f "$4/pause" ]; then
                    printf '%s\\n' '{"progress":"fixture running"}'
                    sleep 0.2
                fi
                if [ "$2" = download ]; then cat "$4/download.json"; else cat "$4/check.json"; fi
                """
                try Data(script.utf8).write(to: python)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            }
            try Data().write(to: runtime.appendingPathComponent("calls.log"))
            try writeReport("首次检查结果")
            let downloaded = EnvironmentReport(state: .ready, detail: "模型下载完成")
            try JSONEncoder().encode(downloaded).write(to: runtime.appendingPathComponent("download.json"))
        }

        @MainActor func makeEnvironment() -> ModelEnvironment {
            ModelEnvironment(directory: runtime, cacheDirectory: cache)
        }

        func writeReport(_ detail: String) throws {
            let weight = EnvironmentReport.Weight(name: "model.bin", bytes: 128, source: "fixture",
                                                  url: URL(string: "https://example.invalid/model.bin"))
            let report = EnvironmentReport(state: .missing, detail: detail, action: "下载模型", python: "fixture", weights: [weight])
            try JSONEncoder().encode(report).write(to: runtime.appendingPathComponent("check.json"))
        }

        func calls() throws -> [Substring] {
            try String(contentsOf: runtime.appendingPathComponent("calls.log"), encoding: .utf8).split(separator: "\n")
        }
    }
}
