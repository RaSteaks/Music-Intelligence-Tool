import Foundation
import Testing
@testable import MusicIntelligenceTool

private final class TestCredentials: CloudCredentialStore {
    var values: [String: String] = [:]
    func read(_ id: String) throws -> String? { values[id] }
    func write(_ value: String?, for id: String) throws { values[id] = value }
}

private final class CloudFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let process = Process()
    var baseURL = ""

    init() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Bundle the stdlib-only fixture so the tested app need not read the
        // developer's Desktop checkout or acquire an unrelated TCC permission.
        let script = try #require(Bundle(for: CloudFixture.self).url(forResource: "cloud_fixture_server", withExtension: "py"))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if let port = try? String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8) {
                baseURL = "http://127.0.0.1:\(port)"; return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        stop()
        throw CloudError.configuration("测试 HTTP 服务没有启动。")
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }

    func connection(path: String = "/v1", style: CloudAPIStyle = .chat) -> ModelConnection {
        var result = ModelConnection()
        result.baseURL = baseURL + path; result.model = "fixture/audio"; result.apiStyle = style
        return result
    }

    func song(seconds: Int = 1) throws -> SongRecord {
        let file = root.appendingPathComponent("private-song.wav")
        try CloudAudio.testWAV(seconds: seconds).write(to: file)
        return SongRecord(url: file, duration: Double(seconds))
    }
}

@MainActor
struct CloudAnalysisTests {
    @Test func connectionLifecycleKeepsCredentialsOutOfFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let keyID = "unit-test-" + UUID().uuidString
        let keychain = KeychainCredentials()
        defer { try? FileManager.default.removeItem(at: root); try? keychain.write(nil, for: keyID) }
        try keychain.write("not-a-real-key", for: keyID)
        #expect(try keychain.read(keyID) == "not-a-real-key")
        try keychain.write("updated-fixture", for: keyID)
        #expect(try keychain.read(keyID) == "updated-fixture")
        try keychain.write(nil, for: keyID)
        #expect(try keychain.read(keyID) == nil)

        let keys = TestCredentials()
        let store = ExternalModels(directory: root, credentials: keys)
        var connection = ModelConnection(); connection.model = "fixture/audio"
        // Reopen a legacy configuration whose credential account is its connection ID.
        try store.save(connection)
        try keys.write("fixture-secret", for: connection.id)
        try store.recordVerification(connection, task: .audio)
        #expect(store.configuration.connections[0].audioAvailable)
        let file = root.appendingPathComponent("connections.json")
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("fixture-secret"))
        let reopened = ExternalModels(directory: root, credentials: keys)
        #expect(try reopened.key(for: connection) == "fixture-secret")
        connection = reopened.configuration.connections[0]; connection.model = "another-model"
        try reopened.save(connection)
        #expect(!reopened.configuration.connections[0].audioAvailable)
        var retargeted = connection
        retargeted.baseURL = "https://API.OPENAI.COM:443/compatible"
        #expect(try reopened.key(for: retargeted) == "fixture-secret")
        retargeted.baseURL = "https://api.openai.com:8443/v1"
        #expect(throws: CloudError.self) { try reopened.key(for: retargeted) }
        retargeted.baseURL = "https://provider.invalid/v1"
        #expect(throws: CloudError.self) { try reopened.key(for: retargeted) }
        #expect(throws: CloudError.self) { try reopened.save(retargeted) }
        #expect(try reopened.key(for: connection) == "fixture-secret")
        try reopened.save(retargeted, newKey: "replacement-fixture")
        let moved = ExternalModels(directory: root, credentials: keys)
        #expect(try moved.key(for: retargeted) == "replacement-fixture")
        #expect(throws: CloudError.self) { try moved.key(for: connection) }
        #expect(try keys.read(connection.id) == nil)
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("replacement-fixture"))
        try reopened.delete(connection.id)
        #expect(keys.values.isEmpty && reopened.configuration.textConnectionID == nil)
        try Data("broken".utf8).write(to: file)
        let broken = ExternalModels(directory: root, credentials: keys)
        #expect(throws: CloudError.self) { try broken.save(connection) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "broken")
    }

    @Test func providerContractEnforcesScopeAndRejectsUnusableResponses() async throws {
        let fixture = try await CloudFixture(); defer { fixture.stop() }
        var song = try fixture.song(seconds: 3)
        song.marks = [Mark.manual("section", from: 0, to: 1, label: "first"),
                      Mark.manual("section", from: 1, to: 2, label: "PRIVATE_GAP"),
                      Mark.manual("section", from: 2, to: 3, label: "last"),
                      Mark.manual("note", from: 0.5, to: 2.5, label: "PRIVATE_CROSSING")]
        song.marks += [Mark(kind: "loudness", start: 0, end: 3, source: "fixture", metrics: ["integrated_lufs": -20]),
                       Mark(kind: "acoustic", start: 0, end: 1, source: "fixture", metrics: ["rms": 0.1]),
                       Mark(kind: "acoustic", start: 0.5, end: 1.5, source: "fixture", metrics: ["rms": 0.95]),
                       Mark(kind: "acoustic", start: 1, end: 2, source: "fixture", metrics: ["rms": 0.9]),
                       Mark(kind: "acoustic", start: 2, end: 3, source: "fixture", metrics: ["rms": 0.3])]
        song.bpm = 120
        let context = song.cloudContext(in: AnalysisRange(start: 0, end: 1))
        #expect(!context.items.contains { $0.kind == "loudness" })
        let client = CloudClient()
        #expect(try await client.models(connection: fixture.connection(), key: "fixture-key").first?.supportsAudio == true)
        for style in CloudAPIStyle.allCases {
            for task in [CloudTaskKind.interpretation, .audio] {
                var connection = fixture.connection(style: style)
                connection.provider = .openRouter; connection.outputMode = .schema; connection.upstream = "fixed-provider"
                let result = try await client.analyze(connection: connection, key: "fixture-key", context: context,
                                                      task: task, audio: task == .audio ? CloudAudio.testWAV() : nil)
                #expect(result.answer.findings.count == 1 && result.model == "fixture/audio-v1")
                #expect(result.usage["total_tokens"] == 120)
                let body = try String(contentsOf: fixture.root.appendingPathComponent("last-request.json"), encoding: .utf8)
                #expect(!body.contains("private-song.wav") && !body.contains(fixture.root.path) && !body.contains("fixture-key"))
                #expect(body.contains("input_audio") == (task == .audio))
                #expect(body.contains("fixed-provider"))
            }
        }
        for failure in ["deny", "redirect", "invalid", "truncated"] {
            do {
                _ = try await client.analyze(connection: fixture.connection(path: "/\(failure)/v1"), key: "fixture-key", context: context, task: .interpretation)
                Issue.record("Unexpectedly accepted \(failure)")
            } catch let error as CloudError {
                if ["invalid", "truncated"].contains(failure) {
                    guard case .rejectedResponse(_, _, _, let usage) = error else { Issue.record("Lost usage"); continue }
                    #expect(usage["cost_usd"] == 0.001)
                }
            }
        }
        let comparison = CloudTaskOptions(focusRanges: [AnalysisRange(start: 0, end: 1), AnalysisRange(start: 2, end: 3)], compactContext: true)
        let selected = song.cloudContext(in: AnalysisRange(start: 0, end: 3), options: comparison)
        let selectedJSON = try String(decoding: selected.data(), as: UTF8.self)
        #expect(!selectedJSON.contains("PRIVATE_GAP") && !selectedJSON.contains("PRIVATE_CROSSING"))
        #expect(!selectedJSON.contains("integrated_lufs") && selected.bpm == nil)
        #expect(selected.items.map(\.id) == [song.sections[0].id, song.sections[2].id])
        #expect(selected.items.compactMap { $0.metrics["mean_rms"] } == [0.1, 0.3])
        #expect(selected.items.compactMap { $0.metrics["coverage_rms"] } == [1, 1])
        let invented = CloudAnswer(findings: [CloudFinding(category: "event", start: 1.3, end: 1.5, label: "gap", content: "", uncertainty: "", evidenceIDs: [song.sections[0].id])])
        #expect(throws: CloudError.self) { try invented.validated(context: selected, task: .comparison) }

        let options = CloudTaskOptions(question: "这里是否已经进鼓？", audioSources: [.original, .drums])
        let question = song.cloudContext(in: context.range, options: options)
        let clip = try await CloudAudio.prepare(source: URL(fileURLWithPath: song.path), range: AnalysisRange(start: 0.25, end: 0.75), directory: fixture.root)
        #expect(clip.count >= 48000 && clip.count < 49000)
        let shortStem = fixture.root.appendingPathComponent("short-stem.wav")
        try CloudAudio.testWAV().write(to: shortStem)
        do {
            _ = try await CloudAudio.prepare(source: shortStem, range: AnalysisRange(start: 0, end: 2), directory: fixture.root)
            Issue.record("Incomplete stem coverage was accepted")
        } catch is CloudError { }
        let attachments = try #require(question.audioReferences).map { CloudAudioAttachment(reference: $0, data: CloudAudio.testWAV()) }
        var connection = fixture.connection(); connection.maxAudioSeconds = 1
        #expect(throws: CloudError.self) { try client.makeRequest(connection: connection, key: "fixture-key", context: question, task: .question, attachments: attachments) }
        connection.maxAudioSeconds = 120
        let request = try client.makeRequest(connection: connection, key: "fixture-key", context: question, task: .question, attachments: attachments)
        #expect(try await client.complete(request, style: .chat, context: question, task: .question).answer.findings.count == 1)
    }

    @Test func analysisReviewLifecyclePreservesEditsAndAvoidsRepeatedRequests() async throws {
        let fixture = try await CloudFixture(); defer { fixture.stop() }
        let input = try fixture.song()
        let keys = TestCredentials()
        let studio = Studio(root: fixture.root.appendingPathComponent("library"), credentials: keys)
        try studio.open(URL(fileURLWithPath: input.path))
        let connection = fixture.connection()
        try studio.externalModels.save(connection, newKey: "fixture-key")
        let range = AnalysisRange(start: 0, end: 1)
        studio.startCloud(connectionID: connection.id, task: .audio, range: range)
        #expect(!studio.cloudRunning && studio.notice?.contains("音频能力未知") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("requests.log").path))
        studio.startCloud(connectionID: connection.id, task: .interpretation, range: range)
        try await waitForCloud(studio)
        try #require(studio.song?.cloudRuns?.last?.status == "完成")
        studio.edit { record in
            let index = record.marks.firstIndex { $0.kind == "insight" }!
            record.marks[index].fields["label"]?.confirmed = ""
            record.marks[index].fields["content"]?.rejected = true
        }
        studio.startCloud(connectionID: connection.id, task: .interpretation, range: range)
        try await waitForCloud(studio)
        #expect(studio.song?.cloudRuns?.count == 1 && requestCount(fixture) == 1)
        let reopened = Studio(root: studio.root, credentials: keys)
        try reopened.open(URL(fileURLWithPath: input.path))
        #expect(reopened.song?.revision == studio.song?.revision)
        #expect(reopened.song?.marks == studio.song?.marks)
        #expect(reopened.song?.marks.first { $0.kind == "insight" }?.fields["label"]?.value == "")
        #expect(reopened.song?.marks.first { $0.kind == "insight" }?.fields["content"]?.value == nil)

        let slow = fixture.connection(path: "/slow/v1")
        try studio.externalModels.save(slow, newKey: "fixture-key")
        studio.startCloud(connectionID: slow.id, task: .interpretation, range: range)
        try await Task.sleep(for: .milliseconds(100))
        studio.edit { $0.marks[0].fields["label"]?.confirmed = "运行期间校对" }
        try await waitForCloud(studio)
        #expect(studio.song?.cloudRuns?.last?.status == "待更新")
        #expect(studio.song?.marks[0].label == "运行期间校对")
        studio.startCloud(connectionID: slow.id, task: .interpretation, range: range)
        try await Task.sleep(for: .milliseconds(100)); studio.cancelCloud()
        try await waitForCloud(studio)
        #expect(studio.song?.cloudRuns?.last?.status == "已取消")
        #expect(studio.song?.marks.filter { $0.kind == "insight" }.count == 2)
    }

    @Test func batchWorkflowResumesPartialResultsAndTracksDependencies() async throws {
        let fixture = try await CloudFixture(); defer { fixture.stop() }
        let input = try fixture.song(seconds: 3)
        let studio = Studio(root: fixture.root.appendingPathComponent("library"), credentials: TestCredentials())
        try studio.open(URL(fileURLWithPath: input.path))
        let connection = fixture.connection(path: "/fail-once/v1")
        try studio.externalModels.save(connection, newKey: "fixture-key")
        let song = try #require(studio.song)
        #expect(throws: CloudError.self) { try CloudBatchPlan.make(song: song, connection: connection, windowSeconds: 1, audioSources: [], maximumRequests: 3) }
        let plan = try CloudBatchPlan.make(song: song, connection: connection, windowSeconds: 1, audioSources: [], maximumRequests: 4)
        studio.startCloudBatch(connectionID: connection.id, summaryConnectionID: connection.id, plan: plan)
        try await waitForCloud(studio)
        try #require(studio.song?.cloudBatches?.last?.status == "部分完成")
        #expect(requestCount(fixture) == 2)
        #expect(studio.song?.unanalyzedRanges(in: AnalysisRange(start: 0, end: 3)) == [AnalysisRange(start: 1, end: 3)])
        studio.startCloudBatch(connectionID: connection.id, summaryConnectionID: connection.id, plan: plan)
        try await waitForCloud(studio)
        try #require(studio.song?.cloudBatches?.last?.status == "完成")
        #expect(requestCount(fixture) == 5)
        #expect(studio.song?.cloudBatches?.last?.submittedRequests == 3)
        let summary = try #require(studio.song?.cloudRuns?.last)
        #expect(summary.task == .overview && summary.options?.inputInsightIDs.count == 3)
        #expect(summary.context?.items.filter { $0.kind == "insight" }.count == 3)
        #expect(summary.status == "完成") // Its own output must never invalidate its input.
        #expect(summary.options?.missingRanges.isEmpty == true)
        studio.startCloudBatch(connectionID: connection.id, summaryConnectionID: connection.id, plan: plan)
        try await waitForCloud(studio)
        #expect(requestCount(fixture) == 5 && studio.song?.cloudBatches?.last?.submittedRequests == 0)
        studio.edit { $0.marks[0].fields["content"] = ReviewedText(hint: "重新核对") }
        #expect(studio.song?.cloudRuns?.first { $0.id == summary.id }?.status == "待更新")
        #expect(studio.song?.cloudBatches?.last?.status == "待更新")
        let slow = fixture.connection(path: "/slow/v1")
        try studio.externalModels.save(slow, newKey: "fixture-key")
        studio.startCloudBatch(connectionID: slow.id, summaryConnectionID: slow.id, plan: plan)
        try await Task.sleep(for: .milliseconds(100)); studio.cancelCloud()
        try await waitForCloud(studio)
        #expect(studio.song?.cloudBatches?.last?.status == "已取消")
        #expect(requestCount(fixture) <= 6)

        let gated = fixture.connection(path: "/gate-second/v1")
        try studio.externalModels.save(gated, newKey: "fixture-key")
        let beforeEdit = requestCount(fixture)
        studio.startCloudBatch(connectionID: gated.id, summaryConnectionID: gated.id, plan: plan, force: true)
        for _ in 0..<100 {
            if requestCount(fixture) >= beforeEdit + 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(requestCount(fixture) == beforeEdit + 2)
        studio.edit { $0.marks.append(.manual("note", from: 0.2, to: 0.4, label: "修改已分析的第一段")) }
        try Data().write(to: fixture.root.appendingPathComponent("release-second"))
        try await waitForCloud(studio)
        #expect(studio.song?.cloudBatches?.last?.status == "部分完成")
        #expect(studio.song?.cloudBatches?.last?.summaryRunID == nil && requestCount(fixture) == beforeEdit + 2)

        // A model comparison is a bounded pair of independent calls on one
        // immutable context, with no implicit third-model judge.
        var second = fixture.connection(style: .responses); second.model = "fixture/second"
        try studio.externalModels.save(second, newKey: "fixture-key")
        let before = requestCount(fixture)
        studio.compareModels(connectionIDs: [connection.id, second.id], task: .interpretation,
                             range: AnalysisRange(start: 0, end: 1), options: CloudTaskOptions())
        try await waitForCloud(studio)
        let comparison = try #require(studio.song?.cloudBatches?.last)
        #expect(comparison.mode == "models" && comparison.status == "完成" && comparison.submittedRequests == 2)
        #expect(requestCount(fixture) == before + 2 && comparison.summaryRunID == nil)
        let inputs = studio.song?.cloudRuns?.filter { comparison.runIDs.contains($0.id) }.map(\.inputFingerprint) ?? []
        #expect(inputs.count == 2 && Set(inputs).count == 1)
    }

    private func requestCount(_ fixture: CloudFixture) -> Int {
        ((try? String(contentsOf: fixture.root.appendingPathComponent("requests.log"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func waitForCloud(_ studio: Studio) async throws {
        for _ in 0..<200 {
            if !studio.cloudRunning { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        studio.cancelCloud()
        Issue.record("Cloud task did not finish within 10 seconds")
    }
}
