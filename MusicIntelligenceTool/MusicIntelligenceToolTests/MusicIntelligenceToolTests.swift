import Foundation
import Testing
@testable import MusicIntelligenceTool

@MainActor
struct MusicIntelligenceToolTests {
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
        #expect(saved.hasCompleted(.lyrics, in: 0...60))
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
        // Local analysis joins the same editing workflow: scoped replacement,
        // independent stem lanes and coverage-aware section summaries.
        let activity = Mark(kind: "event", start: 0, end: 10, source: "PCM",
                            fields: ["event_type": ReviewedText(suggested: "vocals")])
        song.marks.append(activity)
        let fresh = Mark(kind: "event", start: 4, end: 6, source: "PCM",
                         fields: ["event_type": ReviewedText(suggested: "vocals")])
        song.apply(JobResult(marks: [fresh]), job: .events, range: 4..<6)
        #expect(song.marks.filter { $0.kind == "event" }.sorted { $0.start < $1.start }.map(\.start) == [0, 4, 6])
        #expect(song.hasCompleted(.events, in: 4...6) && !song.hasCompleted(.events, in: 0...10))
        let eventIndex = try #require(song.marks.firstIndex { $0.id == fresh.id })
        song.marks[eventIndex].fields["label"] = ReviewedText(confirmed: "人声已核对")
        song.apply(JobResult(marks: [], stems: [:]), job: .structure, range: 0..<10)
        #expect(song.marks[eventIndex].analysisStale == true)
        #expect(!song.hasCompleted(.events, in: 4...6))
        song.apply(JobResult(marks: [fresh]), job: .events, range: 4..<6)
        #expect(song.marks.first { $0.id == fresh.id }?.analysisStale == false)
        #expect(song.marks.first { $0.id == fresh.id }?.label == "人声已核对")
        song.marks += [Mark(kind: "chord", start: 0, end: 10, source: "fixture", fields: ["label": ReviewedText(suggested: "C")]),
                       Mark(kind: "key", start: 0, end: 10, source: "fixture", fields: ["label": ReviewedText(suggested: "C major")])]
        song.key = "C major"
        song.apply(JobResult(marks: []), job: .harmony, range: 4..<6)
        #expect(song.hasCompleted(.harmony, in: 4...6) && !song.hasCompleted(.harmony, in: 0...10))
        #expect(song.marks.filter { $0.kind == "chord" }.map(\.start).sorted() == [0, 6])
        #expect(song.key == "C major" && song.marks.contains { $0.kind == "key" && $0.end == 10 })
        song.marks += [Mark(kind: "emotion", start: 0, end: 1, source: "fixture", fields: ["label": ReviewedText(suggested: "紧张")]),
                       Mark(kind: "emotion", start: 1, end: 10, source: "fixture", fields: ["label": ReviewedText(suggested: "平静")]),
                       Mark(kind: "acoustic", start: 8, end: 10, source: "fixture", metrics: ["short_lufs": -10]),
                       Mark(kind: "acoustic", start: 0, end: 2, source: "fixture", metrics: ["short_lufs": -20])]
        let summary = song.summary(for: song.sections[0])
        #expect(summary.contains("段尾响度上升") && summary.contains("主要听感 · 平静"))
        let metrics = song.sectionMetrics(in: AnalysisRange(start: 0, end: 10))
        #expect(metrics["mean_short_lufs"] == -15 && metrics["coverage_short_lufs"] == 0.4)
    }

    @Test func deletingSectionsPreservesCoverageAndCanBeUndone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root)
        try studio.open(#require(Bundle.main.url(forResource: "Study", withExtension: "wav")))
        let original = try #require(studio.song).sections
        try #require(original.count == 3)
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

}
