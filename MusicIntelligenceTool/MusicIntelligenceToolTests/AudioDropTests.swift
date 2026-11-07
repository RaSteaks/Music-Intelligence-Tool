import Foundation
import Testing
@testable import MusicIntelligenceTool

@MainActor
struct AudioDropTests {
    @Test func importSwitchAndReopenPreserveEdits() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let studio = Studio(root: fixture.library)
        #expect(studio.openDroppedAudio([fixture.first]))
        try await waitForWaveform(studio)
        #expect(studio.song?.path == fixture.first.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(studio.song?.duration ?? 0 > 0)
        studio.edit { $0.marks[0].fields["label"] = ReviewedText(confirmed: "手工段落") }

        let reopened = Studio(root: fixture.library)
        #expect(reopened.openDroppedAudio([fixture.first]))
        try await waitForWaveform(reopened)
        #expect(reopened.row?.label == "手工段落")
        #expect(reopened.song?.revision == studio.song?.revision)
        let firstID = studio.song?.trackID
        studio.seek(8)
        studio.selection = 2...5
        studio.zoom = 3

        #expect(studio.openDroppedAudio([fixture.second]))
        try await waitForWaveform(studio)
        #expect(studio.song?.trackID != firstID)
        #expect(studio.song?.path == fixture.second.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(studio.cursor == 0)
        #expect(studio.selection == nil)
        #expect(studio.zoom == 1)
        #expect(!studio.playing)
    }

    @Test func invalidImportsAndBusyStatePreserveCurrentSong() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let studio = Studio(root: fixture.library)
        #expect(studio.openDroppedAudio([fixture.first]))
        try await waitForWaveform(studio)
        let trackID = studio.song?.trackID
        studio.selection = 2...5
        let text = fixture.root.appendingPathComponent("notes.txt")
        let corrupt = fixture.root.appendingPathComponent("broken.wav")
        try Data("not an audio file".utf8).write(to: text)
        try Data("not an audio file".utf8).write(to: corrupt)
        let remote = try #require(URL(string: "https://example.invalid/song.wav"))
        for urls in [[], [fixture.first, fixture.second], [text], [corrupt], [remote],
                     [fixture.root.appendingPathComponent("missing.wav")]] {
            studio.notice = nil
            #expect(!studio.openDroppedAudio(urls))
            #expect(studio.notice != nil)
            #expect(studio.song?.trackID == trackID)
            #expect(studio.selection == 2...5)
        }
        studio.activeJob = .structure
        defer { studio.activeJob = nil }
        studio.seek(8)
        #expect(!studio.openDroppedAudio([fixture.second]))
        #expect(studio.notice == "请等待当前分析或取消后切换歌曲。")
        #expect(studio.song?.trackID == trackID)
        #expect(studio.openDroppedAudio([fixture.first]))
        #expect(studio.cursor == 8)
    }

    private func waitForWaveform(_ studio: Studio) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while studio.peaks.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!studio.peaks.isEmpty)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var library: URL { root.appendingPathComponent("library") }
        var first: URL { root.appendingPathComponent("first.wav") }
        var second: URL { root.appendingPathComponent("拖入音频.WAV") }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let study = try #require(Bundle.main.url(forResource: "Study", withExtension: "wav"))
            try FileManager.default.copyItem(at: study, to: first)
            try FileManager.default.copyItem(at: study, to: second)
        }
    }
}
