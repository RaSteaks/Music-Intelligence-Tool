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

    @Test func cleanupSelectsKnownModelFilesAndVirtualEnvironments() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }

        func write(_ relative: String) throws -> URL {
            let path = root.appendingPathComponent(relative)
            try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: path)
            return path
        }

        let runtime = root.appendingPathComponent("runtime")
        let userHome = root.appendingPathComponent("user")
        let variables = ["XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
                         "TORCH_HOME": root.appendingPathComponent("torch").path,
                         "HF_HUB_CACHE": root.appendingPathComponent("hub").path,
                         "MIT_WHISPER_MODEL": "turbo"]
        let weights = try ["cache/whisper/base.pt", "cache/whisper/large-v3-turbo.pt",
                           "torch/hub/checkpoints/955717e8-8726e21a.th",
                           "user/.cache/all-in-one-mlx/weights/.harmonix-fold0_mlx.npz.pending.tmp",
                           "user/.cache/demucs-mlx/htdemucs.safetensors"].map(write)
        let mert = try write("hub/models--m-a-p--MERT-v1-95M/ref").deletingLastPathComponent()
        let emotion = try write("runtime/.models/Music2Emotion/music2emo.py").deletingLastPathComponent()
        let head = try write("runtime/.models/Music2Emotion/saved_models/J_all.ckpt")
        let venv = try write("runtime/.venv-structure/pyvenv.cfg").deletingLastPathComponent()
        let external = try write("other/venv/pyvenv.cfg").deletingLastPathComponent()
        try files.createSymbolicLink(at: runtime.appendingPathComponent(".venv"), withDestinationURL: external)
        try files.createSymbolicLink(at: userHome.appendingPathComponent(".cache/demucs-mlx/htdemucs_config.json"),
                                     withDestinationURL: external.appendingPathComponent("pyvenv.cfg"))
        _ = try write("cache/whisper/small.pt")
        _ = try write("hub/models--someone--unrelated/ref")
        _ = try write("runtime/.venv-unrelated/pyvenv.cfg")
        _ = try write("runtime/.venv-align/notes.txt")
        _ = try write("runtime/Tracks/analysis.json")

        let modelsOnly = ModelCleanup.models.targets(in: runtime, home: userHome, variables: variables)
        #expect(modelsOnly.errors.isEmpty)
        #expect(Set(modelsOnly.items.map(\.path)) == Set((weights + [mert, head]).map(\.path)))

        let everything = ModelCleanup.modelsAndEnvironment.targets(in: runtime, home: userHome, variables: variables)
        #expect(everything.errors.isEmpty)
        #expect(Set(everything.items.map(\.path)) == Set((weights + [mert, emotion, venv]).map(\.path)))

        let customModel = ["MIT_WHISPER_MODEL": weights[0].path]
        let custom = ModelCleanup.models.targets(in: runtime, home: userHome,
                                                 variables: variables.merging(customModel) { _, new in new })
        #expect(custom.errors.isEmpty)
        #expect(Set(custom.items.map(\.path)) == Set((Array(weights.dropFirst(2)) + [mert, head]).map(\.path)))
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
