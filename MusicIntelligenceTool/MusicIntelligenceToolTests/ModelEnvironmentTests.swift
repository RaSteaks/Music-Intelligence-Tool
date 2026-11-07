import Foundation
import Testing
@testable import MusicIntelligenceTool

@MainActor
struct ModelEnvironmentTests {
    @Test func cachedEnvironmentsRefreshDownloadAndSwitchIndependently() async throws {
        let first = try Fixture(), second = try Fixture()
        defer { try? FileManager.default.removeItem(at: first.root); try? FileManager.default.removeItem(at: second.root) }
        let models = first.makeEnvironment()
        models.checkIfNeeded(); try await finish(models)
        let checkedAt = try #require(models.checkedAt)
        #expect(try first.calls().count == ModelFeature.allCases.count)
        try first.writeReport("新的环境状态")
        let reopened = first.makeEnvironment()
        reopened.checkIfNeeded()
        #expect(!reopened.isBusy && reopened.checkedAt == checkedAt)
        #expect(reopened.reports[.base]?.detail == "首次检查结果")
        #expect(reopened.reports[.lyrics]?.weights?.first?.bytes == 128)
        reopened.refresh(); try await finish(reopened)
        #expect(reopened.reports[.base]?.detail == "新的环境状态")
        let refreshedAt = reopened.checkedAt
        reopened.download(.lyrics); try await finish(reopened)
        #expect(reopened.reports[.lyrics]?.state == .ready && reopened.reports[.base]?.state == .missing)
        #expect(reopened.checkedAt == refreshedAt)
        #expect(try first.calls().last == "download:lyrics")
        try second.writeReport("第二个运行目录")
        reopened.checkIfNeeded(in: second.runtime); try await finish(reopened)
        #expect(reopened.reports[.base]?.detail == "第二个运行目录")
        reopened.checkIfNeeded(in: first.runtime)
        #expect(!reopened.isBusy && reopened.reports[.lyrics]?.detail == "模型下载完成")
        #expect(try first.calls().count == ModelFeature.allCases.count * 2 + 1)
        #expect(try second.calls().count == ModelFeature.allCases.count)
    }

    @Test func failuresCorruptionAndCancellationKeepRecoverableSnapshots() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("{\"error\":\"fixture failure\"}\n".utf8).write(to: fixture.runtime.appendingPathComponent("check.json"))
        let models = fixture.makeEnvironment()
        models.checkIfNeeded(); try await finish(models)
        #expect(models.reports[.base]?.state == .blocked)
        let reopened = fixture.makeEnvironment()
        reopened.checkIfNeeded()
        #expect(!reopened.isBusy && reopened.errors[.base] == models.errors[.base])
        #expect(try fixture.calls().count == ModelFeature.allCases.count)
        try fixture.writeReport("检查已恢复")
        reopened.refresh(); try await finish(reopened)
        #expect(reopened.errors.isEmpty && reopened.reports[.base]?.detail == "检查已恢复")
        let directory = try #require(FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil).first)
        try Data("invalid saved data".utf8).write(to: directory.appendingPathComponent("check.json"))
        let recovered = fixture.makeEnvironment()
        #expect(recovered.checkedAt == nil)
        recovered.checkIfNeeded(); try await finish(recovered)
        recovered.checkIfNeeded()
        #expect(!recovered.isBusy)
        #expect(try fixture.calls().count == ModelFeature.allCases.count * 3)
        let checkedAt = recovered.checkedAt
        try fixture.writeReport("未完成的新检查")
        try Data().write(to: fixture.runtime.appendingPathComponent("pause"))
        recovered.refresh()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while recovered.progress != "fixture running", recovered.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(recovered.progress == "fixture running")
        recovered.cancel(); try await finish(recovered)
        let saved = fixture.makeEnvironment()
        #expect(saved.checkedAt == checkedAt && saved.reports[.base]?.detail == "检查已恢复")
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
