import AppKit
import Testing
@testable import MusicIntelligenceTool

@MainActor
struct TimelineInteractionTests {
    @Test func overflowingLanesScrollBelowTheWaveControls() {
        var song = SongRecord(url: URL(fileURLWithPath: "/lanes.wav"), duration: 60)
        let kinds = ["lyric", "word", "note", "chord", "emotion", "insight", "tempo", "repetition"]
        song.marks += ["silence", "vocals", "drums", "bass"].map {
            Mark(kind: "event", start: 0, end: 1, source: "test", fields: ["event_type": ReviewedText(suggested: $0)])
        }
        let visible = Set(kinds + ["event"])
        for height: CGFloat in [210, 300, 600] {
            let layout = CanvasLayout(record: song, visible: visible, selected: nil, height: height, scroll: 99)
            #expect(layout.lanes.count == 12)
            #expect(layout.lanesTop >= CanvasLayout.lanesFloor)
            #expect(layout.visibleLanes.allSatisfy { layout.laneTop($0) > CanvasLayout.lanesFloor })
            #expect(layout.visibleLanes.upperBound == 12)
        }
        let small = CanvasLayout(record: song, visible: visible, selected: nil, height: 300)
        #expect(small.overflows && small.firstLane == 0 && !small.canScrollUp && small.canScrollDown)
        // Hiding one event sub-lane removes only that lane.
        let hidden = CanvasLayout(record: song, visible: visible, hidden: ["event:vocals"], selected: nil, height: 900)
        #expect(hidden.lanes.filter { $0.hasPrefix("event:") } == ["event:silence", "event:drums", "event:bass"])
    }

    @Test func blankLyricsReadAsUnfilledUntilCleared() {
        var lyric = Mark.manual("lyric", from: 0, to: 1, label: "")
        #expect(lyric.provenance == .empty && lyric.fields["label"]?.provenance == .empty)
        #expect(lyric.fields["label"]?.confirmed == nil && lyric.label == "")
        lyric.fields["label"]?.confirmed = "词"
        #expect(lyric.provenance == .confirmed)
        lyric.fields["label"]?.confirmed = ""
        #expect(lyric.provenance == .cleared && lyric.fields["label"]?.provenance == .cleared)
    }

    @Test func cuePointsBuildSectionsAndSupportCorrections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let studio = Studio(root: root)
        studio.song = SongRecord(url: root.appendingPathComponent("song.wav"), duration: 60)

        studio.seek(12.5)
        studio.markPoint(.exit)
        #expect(studio.selection == 0...12.5)
        studio.add("section")
        studio.seek(23.75)
        studio.markPoint(.exit)
        #expect(studio.selection == 12.5...23.75)
        studio.add("section")
        studio.seek(50)
        studio.markPoint(.exit)
        #expect(studio.selection == 23.75...50)
        studio.add("section")
        #expect(studio.song?.sections.map(\.start) == [0, 12.5, 23.75, 50])
        #expect(studio.song?.sections.map(\.end) == [12.5, 23.75, 50, 60])
        studio.selection = 0...20
        studio.seek(10)
        studio.markPoint(.entry)
        #expect(studio.inPoint == 10)
        #expect(studio.outPoint == nil)
        studio.seek(30)
        studio.markPoint(.exit)
        #expect(studio.selection == 10...30)
        studio.seek(40)
        studio.markPoint(.exit)
        #expect(studio.selection == 30...40)
        studio.selection = 10...20
        studio.seek(20)
        studio.markPoint(.exit)
        #expect(studio.selection == 10...20)
        studio.seek(15)
        studio.markPoint(.exit)
        #expect(studio.selection == 10...15)
        studio.seek(5)
        studio.markPoint(.exit)
        #expect(studio.selection == 0...5)
        studio.selection = nil
        studio.seek(8)
        studio.markPoint(.exit)
        #expect(studio.selection == 0...8)
    }

    @Test func rulerAndWaveformGesturesKeepSeparateResponsibilities() throws {
        let studio = makeStudio()
        studio.selection = 5...15
        studio.song?.marks.append(Mark(kind: "beat", start: 30, end: 30, source: "fixture"))
        let canvas = try makeCanvas(studio)
        let selected = studio.selected
        canvas.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 100, y: 10), in: canvas))
        #expect(studio.cursor == 10)
        // Crossing into the waveform must keep seeking, including near a beat with snapping enabled.
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 302, y: 90), in: canvas))
        #expect(abs(studio.cursor - 30.2) < 0.0001)
        #expect(studio.selection == 5...15)
        canvas.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 450, y: 120), in: canvas))
        #expect(studio.cursor == 45)
        #expect(studio.selection == 5...15)
        #expect(studio.selected == selected)
        // The same workspace supports zoomed scrubbing, range selection and handle edits.
        studio.selection = nil
        let zoomed = try makeCanvas(studio, window: 10...20)
        zoomed.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 300, y: 25), in: zoomed))
        #expect(studio.cursor == 15)
        zoomed.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: -50, y: 10), in: zoomed))
        #expect(studio.cursor == 10)
        zoomed.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 650, y: 10), in: zoomed))
        #expect(studio.cursor == 20 && studio.selection == nil)
        canvas.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 200, y: 160), in: canvas))
        canvas.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 400, y: 160), in: canvas))
        canvas.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 400, y: 160), in: canvas))
        #expect(studio.selection == 20...40 && studio.cursor == 20)
        studio.selection = 5...15
        let handles = try makeCanvas(studio)
        handles.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 145, y: 99), in: handles))
        handles.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 190, y: 99), in: handles))
        handles.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 190, y: 99), in: handles))
        #expect(studio.selection == 5...19 && studio.cursor == 20)
    }

    private func makeStudio() -> Studio {
        let studio = Studio(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        studio.song = SongRecord(url: URL(fileURLWithPath: "/study.wav"), duration: 60)
        studio.selected = studio.song?.sections.first?.id
        return studio
    }

    private func makeCanvas(_ studio: Studio, window: ClosedRange<Double> = 0...60) throws -> WaveCanvas {
        let canvas = WaveCanvas(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        canvas.input = WaveformView(record: try #require(studio.song), peaks: [], visible: ["section"], selected: studio.selected,
                                    inPoint: studio.inPoint, outPoint: studio.outPoint, cursor: studio.cursor,
                                    window: window, snap: studio.snap, inShortcut: "i", outShortcut: "o",
                                    onShortcut: studio.markPoint, onMovePoint: studio.setPoint,
                                    onSeek: studio.seek, onPick: studio.select,
                                    onRange: { studio.selection = $0; studio.seek($0.lowerBound) },
                                    onResize: { _, _, _ in Issue.record("Unexpected boundary edit") })
        return canvas
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in canvas: WaveCanvas) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
}
