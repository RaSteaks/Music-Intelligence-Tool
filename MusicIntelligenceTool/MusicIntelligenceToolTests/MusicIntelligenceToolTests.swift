import Foundation
import Testing
@testable import MusicIntelligenceTool

@MainActor
struct MusicIntelligenceToolTests {
    @Test func agentMessageContainsSavedHintsAndReadyToUseQueries() throws {
        var song = SongRecord(url: URL(fileURLWithPath: "/private/example/练习.wav"), duration: 12.375)
        let hint = "第 3 秒像是“鼓点”\n请试听"
        song.marks[0].fields["mood"] = ReviewedText(confirmed: "紧张", hint: hint)
        let note = Mark.manual("note", from: 3, to: 3, label: "入鼓")
        song.marks += [note, Mark(kind: "beat", start: 3, end: 3, source: "model")]

        let endpoint = "http://127.0.0.1:18765/mcp"
        let message = try song.agentMessage(mcpEndpoint: endpoint)
        #expect(message.contains(endpoint))
        #expect(message.contains("练习.wav"))
        let lines = message.components(separatedBy: "\n")
        for name in ["get_music_overview", "get_music_timeline"] {
            let line = try #require(lines.first { $0.hasPrefix(name + " ") })
            let json = Data(line.dropFirst(name.count + 1).utf8)
            let args = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            #expect(args["track_id"] as? String == song.trackID)
            if name == "get_music_timeline" {
                #expect(args["end_s"] as? Double == song.duration)
                #expect(args["confirmed_only"] as? Bool == false)
                #expect(args["types"] as? [String] == ["note", "section"])
            }
        }
        let snapshot = try #require(lines.last)
        let marks = try JSONDecoder().decode([Mark].self, from: Data(snapshot.utf8))
        #expect(marks == [song.marks[0], note])
    }

    @Test func correctedBoundarySurvivesLateResultsAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var song = SongRecord(url: root.appendingPathComponent("song.wav"), duration: 60)
        let first = try #require(song.sections.first?.id)
        song.split(first, at: 43)
        song.moveBoundary(left: first, to: 41.80)
        let verse = Mark(kind:"lyric",start:43,end:52,source:"Whisper",fields:["label":ReviewedText(suggested:"原词")])
        song.apply(JobResult(marks:[verse]),job:.lyrics,range:0..<60)
        try song.save(in:root)
        let file = root.appendingPathComponent(song.trackID).appendingPathComponent("analysis.json")
        let saved = try JSONDecoder().decode(SongRecord.self,from:Data(contentsOf:file))
        #expect(saved.revision == 1)
        #expect(saved.sections.map(\.start) == [0,41.8])
        #expect(saved.sections.first?.end == 41.8)
        #expect(saved.sections.last?.startConfirmed == true)
        #expect(saved.marks.first(where: { $0.kind=="lyric" })?.label == "原词")
        let i = try #require(song.marks.firstIndex(where: { $0.id==verse.id }))
        song.marks[i].fields["label"]?.confirmed = "校对词"
        song.apply(JobResult(marks:[verse]),job:.lyrics,range:0..<60)
        #expect(song.marks.filter { $0.kind=="lyric" }.map(\.label) == ["校对词"])
    }

    @Test func sectionAndLyricOperationsKeepAdjacentTimesAndInvalidateWords() throws {
        var song = SongRecord(url:URL(fileURLWithPath:"/study.wav"),duration:10)
        let id = try #require(song.sections.first?.id)
        song.split(id,at:0); song.split(id,at:10)
        #expect(song.sections.count == 1)
        song.split(id,at:4)
        song.moveBoundary(left:id,to:11)
        #expect(song.sections.first?.end == 4)
        song.mergeNext(id)
        #expect(song.sections.map(\.end) == [10])
        let lyric = Mark.manual("lyric",from:2,to:8,label:"first")
        song.marks += [lyric, Mark(kind:"word", start:2,end:3,source:"WhisperX")]
        song.split(lyric.id,at:5)
        #expect(song.marks.filter { $0.kind=="lyric" }.map(\.label) == ["first",""])
        #expect(!song.marks.contains { $0.kind=="word" })
        #expect(song.status["alignment"] == "待更新")
        song.mergeNext(lyric.id)
        #expect(song.marks.filter { $0.kind=="lyric" }.count == 1)
    }

    @Test func deletingSectionsPreservesCoverageAndCanBeUndone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root)
        try studio.open(#require(Bundle.main.url(forResource: "Study", withExtension: "wav")))
        let original = try #require(studio.song).sections
        #expect(original.count == 3)
        let first = try #require(original.first)
        let middle = original[1]
        let last = try #require(original.last)

        studio.select(middle)
        studio.deleteSection(middle.id)
        #expect(studio.selected == first.id)
        #expect(studio.song?.sections.map(\.id) == [first.id, last.id])
        #expect(studio.song?.sections.first?.end == last.start)
        studio.undo()
        #expect(studio.song?.sections == original)

        studio.deleteSection(first.id)
        #expect(studio.song?.sections.first?.start == first.start)
        #expect(studio.song?.sections.first?.fields == middle.fields)
        studio.deleteSection(last.id)
        #expect(studio.song?.sections.last?.end == last.end)
        let revision = studio.song?.revision
        studio.deleteSection(middle.id)
        #expect(studio.song?.sections.map(\.id) == [middle.id])
        #expect(studio.song?.revision == revision)
    }

    @Test func waveformAndEditorPersistHumanChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let demo = try #require(Bundle.main.url(forResource:"Study",withExtension:"wav"))
        let peaks = try Studio.waveform(demo)
        #expect(peaks.count == 24000)
        #expect(peaks.prefix(500).allSatisfy { $0 == 0 })
        #expect(peaks.max() ?? 0 > 0.1)
        let studio = Studio(root:root)
        try studio.open(demo)
        // An out-point can be marked first. Seeking to the other edge must keep it.
        studio.seek(8)
        studio.setPoint(.exit, at: studio.position)
        #expect(studio.selection == nil)
        studio.seek(2)
        studio.setPoint(.entry, at: studio.position)
        #expect(studio.selection == 2...8)
        studio.add("note")
        #expect(studio.row?.start == 2)
        #expect(studio.row?.end == 8)
        studio.undo()
        #expect(studio.song?.marks.contains { $0.kind=="note" } == false)
        studio.setPoint(.entry, at: 12)
        #expect(studio.outPoint == nil)
        studio.setPoint(.exit, at: 15)
        #expect(studio.selection == 12...15)
        let next = Studio(root:root)
        try next.open(demo)
        #expect(next.song?.revision == studio.song?.revision)
        #expect(next.song?.marks == studio.song?.marks)
    }
}
