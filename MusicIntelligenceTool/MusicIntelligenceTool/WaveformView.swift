import AppKit
import SwiftUI

/// Row geometry shared by the canvas and the track-name gutter beside it.
/// The ruler, section band and cue handles keep fixed positions so gestures stay predictable.
struct CanvasLayout {
    static let rulerHeight: CGFloat = 27
    static let bandTop: CGFloat = 27
    static let bandBottom: CGFloat = 67
    static let waveTop: CGFloat = 72
    static let laneHeight: CGFloat = 20
    static let laneStep: CGFloat = 22
    static let gutterWidth: CGFloat = 72
    static let titles: [String: String] = [
        "lyric": "歌词", "word": "字词", "note": "注释", "chord": "和弦", "emotion": "情绪",
        "insight": "解读", "tempo": "速度", "repetition": "重复",
        "event:silence": "停顿", "event:vocals": "人声", "event:drums": "鼓", "event:bass": "贝斯"
    ]

    /// Lanes never rise above this line, so the section band, cue handles and the gutter's track menu stay clear.
    /// Lanes that do not fit scroll inside their own region.
    static let lanesFloor: CGFloat = 118

    let lanes: [String]
    let height: CGFloat
    /// Number of lanes drawn at once, and the index of the first one.
    let visibleCount: Int
    let firstLane: Int

    init(record: SongRecord, visible: Set<String>, hidden: Set<String> = [], selected: String?, height: CGFloat,
         scroll: Int = 0) {
        let picked = record.marks.first { $0.id == selected }
        // A selected semantic event borrows the insight lane so its range is visible.
        let semanticEvent = picked?.kind == "insight" && picked?.fields["category"]?.value == "event" && visible.contains("event")
        let ordinary = ["lyric", "word", "note", "chord", "emotion", "insight", "tempo", "repetition"].filter {
            visible.contains($0) || ($0 == "insight" && semanticEvent)
        }
        let eventTypes = Set(record.marks.filter { $0.kind == "event" }.compactMap { $0.fields["event_type"]?.value })
        let events = visible.contains("event")
            ? ["silence", "vocals", "drums", "bass"].filter { eventTypes.contains($0) }.map { "event:" + $0 }
                .filter { !hidden.contains($0) } : []
        lanes = ordinary + events
        self.height = height
        let capacity = max(1, Int((height - 4 - Self.lanesFloor - 1) / Self.laneStep))
        visibleCount = min(lanes.count, capacity)
        firstLane = min(max(0, scroll), lanes.count - visibleCount)
    }

    static func laneKey(_ row: Mark) -> String {
        row.kind == "event" ? "event:" + (row.fields["event_type"]?.value ?? "silence") : row.kind
    }
    var visibleLanes: Range<Int> { firstLane..<(firstLane + visibleCount) }
    var overflows: Bool { lanes.count > visibleCount }
    var canScrollUp: Bool { firstLane > 0 }
    var canScrollDown: Bool { firstLane + visibleCount < lanes.count }
    /// Only meaningful for indices in `visibleLanes`.
    func laneTop(_ index: Int) -> CGFloat { height - 4 - Self.laneStep * CGFloat(firstLane + visibleCount - index) }
    var lanesTop: CGFloat { lanes.isEmpty ? height : height - 4 - Self.laneStep * CGFloat(visibleCount) - 1 }
    var waveBottom: CGFloat { max(Self.waveTop + 12, lanesTop - 6) }
    var waveMid: CGFloat { (Self.waveTop + waveBottom) / 2 }
    var waveHalf: CGFloat { max(6, (waveBottom - Self.waveTop) / 2) }
}

struct WaveformView: NSViewRepresentable {
    let record: SongRecord
    let peaks: [Float]
    let visible: Set<String>
    let selected: String?
    let inPoint: Double?
    let outPoint: Double?
    let cursor: Double
    let window: ClosedRange<Double>
    let snap: Bool
    let inShortcut: String
    let outShortcut: String
    let onShortcut: (CueEdge) -> Void
    let onMovePoint: (CueEdge, Double) -> Void
    let onSeek: (Double) -> Void
    let onPick: (Mark) -> Void
    let onRange: (ClosedRange<Double>) -> Void
    let onResize: (String, Bool, Double) -> Void
    /// Label the ruler with bar numbers counted from detected downbeats.
    var bars = false
    /// Event sub-lanes the person hid individually, and the first lane shown when lanes overflow.
    var hiddenLanes: Set<String> = []
    var laneScroll = 0
    var onLaneScroll: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> WaveCanvas {
        let view = WaveCanvas()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("波形时间轴")
        view.setAccessibilityIdentifier("waveform")
        return view
    }
    func updateNSView(_ view: WaveCanvas, context: Context) { view.input = self }
}

/// Only the playhead moves during playback, so it lives in its own view and the canvas is not redrawn per frame.
private final class PlayheadView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        Tone.ink.ns.setFill()
        NSRect(x: bounds.midX - 0.75, y: 20, width: 1.5, height: max(0, bounds.height - 20)).fill()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: bounds.midX - 4.5, y: 19))
        handle.line(to: NSPoint(x: bounds.midX + 4.5, y: 19))
        handle.line(to: NSPoint(x: bounds.midX, y: 26))
        handle.close()
        handle.fill()
    }
}

final class WaveCanvas: NSView {
    var input: WaveformView? {
        didSet {
            if needsRedraw(from: oldValue) { needsDisplay = true }
            noteDevelopment(from: oldValue)
            updatePlayhead()
            if oldValue?.inPoint != input?.inPoint || oldValue?.outPoint != input?.outPoint || oldValue?.window != input?.window {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    private var anchor: Double?
    private var dragTime: Double?
    private var resizing: (String, Bool)?
    private var movingPoint: CueEdge?
    private var seeking = false
    private var keyMonitor: Any?
    private var picked: Mark?
    private var hits: [(rect: NSRect, row: Mark)] = []
    private var hoverX: CGFloat?
    private var tracking: NSTrackingArea?
    private let playhead = PlayheadView()
    private var cacheKey: (track: String, revision: Int)?
    private var sectionSummaries: [String: String] = [:]
    private var formLetters: [String: String] = [:]
    private var downbeats: [Double] = []
    private var beats: [Double] = []
    private var developing: [String: Date] = [:]
    private var developTimer: Timer?
    private static let developDuration = 0.6
    private var rulerRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: CanvasLayout.rulerHeight) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(playhead)
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        addSubview(playhead)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if newWindow == nil { developTimer?.invalidate(); developTimer = nil }
        guard newWindow != nil else { return }
        // Allow marking while a transport control has focus, but leave text editors and other windows alone.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let i = self.input, let window = self.window,
                  window.isKeyWindow, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView),
                  (window.firstResponder as? NSControl)?.currentEditor() == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            let edge: CueEdge
            switch key {
            case i.inShortcut: edge = .entry
            case i.outShortcut: edge = .exit
            default: return event
            }
            if !event.isARepeat { i.onShortcut(edge) }
            return nil
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        updatePlayhead()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func needsRedraw(from old: WaveformView?) -> Bool {
        guard let old, let new = input else { return true }
        return old.record.trackID != new.record.trackID || old.record.revision != new.record.revision
            || old.record.marks.count != new.record.marks.count || old.record.duration != new.record.duration
            || old.peaks.count != new.peaks.count || old.visible != new.visible || old.selected != new.selected
            || old.inPoint != new.inPoint || old.outPoint != new.outPoint || old.window != new.window
            || old.bars != new.bars || old.snap != new.snap
            || old.hiddenLanes != new.hiddenLanes || old.laneScroll != new.laneScroll
    }

    /// A module that just finished fades its lanes in. This is the only motion not caused by the user.
    private func noteDevelopment(from old: WaveformView?) {
        guard let old, let new = input, old.record.trackID == new.record.trackID,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let now = Date()
        for job in AnalysisJob.allCases where new.record.status[job.rawValue] == "完成" && old.record.status[job.rawValue] != "完成" {
            for kind in job.kinds { developing[kind] = now }
        }
        guard !developing.isEmpty, developTimer == nil else { return }
        developTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.developing = self.developing.filter { Date().timeIntervalSince($0.value) < Self.developDuration }
                self.needsDisplay = true
                if self.developing.isEmpty { timer.invalidate(); self.developTimer = nil }
            }
        }
    }
    private func developAlpha(_ kind: String) -> CGFloat {
        guard let start = developing[kind] else { return 1 }
        return CGFloat(min(1, max(0.08, Date().timeIntervalSince(start) / Self.developDuration)))
    }

    private func updatePlayhead() {
        guard let i = input, bounds.width > 0 else { playhead.isHidden = true; return }
        let head = resizing == nil ? i.cursor : (dragTime ?? i.cursor)
        let xx = x(head)
        playhead.isHidden = xx < -5 || xx > bounds.width + 5
        let frame = NSRect(x: xx - 5, y: 0, width: 10, height: bounds.height)
        if playhead.frame != frame { playhead.frame = frame }
    }

    private func refreshCaches(_ i: WaveformView) {
        guard cacheKey?.track != i.record.trackID || cacheKey?.revision != i.record.revision else { return }
        let sections = i.record.sections
        sectionSummaries = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, i.record.summary(for: $0)) })
        // Sections that share a name share a form letter, so repeats read as A B A B C.
        var letters: [String: String] = [:]
        var byName: [String: String] = [:]
        for row in sections {
            let name = row.fields["label"]?.value ?? ""
            let key = name.isEmpty ? row.id : name
            if byName[key] == nil {
                let n = byName.count
                byName[key] = n < 26 ? String(UnicodeScalar(UInt8(65 + n))) : String(n + 1)
            }
            letters[row.id] = byName[key]
        }
        formLetters = letters
        downbeats = i.record.marks.filter { $0.kind == "downbeat" && $0.analysisStale != true }.map(\.start).sorted()
        let beatKind = i.record.marks.contains { $0.kind == "beat" && $0.analysisStale != true } ? "beat" : "rhythm_beat"
        beats = i.record.marks.filter { $0.kind == beatKind && $0.analysisStale != true }.map(\.start).sorted()
        cacheKey = (i.record.trackID, i.record.revision)
    }

    private func x(_ time: Double) -> CGFloat {
        guard let i = input else { return 0 }
        return (time-i.window.lowerBound)/max(0.001, i.window.upperBound-i.window.lowerBound)*bounds.width
    }
    private func time(_ x: CGFloat, snap: Bool) -> Double {
        guard let i = input else { return 0 }
        let span = i.window.upperBound-i.window.lowerBound
        let t = i.window.lowerBound + min(1, max(0, x/max(1, bounds.width))) * span
        let kind = i.record.marks.contains { $0.kind == "beat" && $0.analysisStale != true } ? "beat" : "rhythm_beat"
        if snap && i.snap, let beat = i.record.marks.filter({ $0.kind == kind && $0.analysisStale != true && abs($0.start-t) < 7*span/bounds.width })
            .min(by: { abs($0.start-t) < abs($1.start-t) }) { return beat.start }
        return t
    }
    private func line(_ a: NSPoint, _ b: NSPoint, _ color: NSColor, width: CGFloat = 1, dash: [CGFloat] = []) {
        color.setStroke()
        let path = NSBezierPath(); path.move(to: a); path.line(to: b)
        path.lineWidth = width
        if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
        path.stroke()
    }
    private func text(_ string: String, _ rect: NSRect, font: NSFont, color: NSColor, strike: Bool = false,
                      align: NSTextAlignment = .left) {
        guard rect.width > 4 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = align
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if strike {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = color
        }
        (string as NSString).draw(in: rect, withAttributes: attributes)
    }
    private func seal(at point: NSPoint) {
        Tone.human.ns.setFill()
        NSRect(x: point.x, y: point.y, width: 6, height: 6).fill()
    }
    /// A small vermilion flag marks a human hint attached to an item.
    private func flag(at point: NSPoint) {
        line(NSPoint(x: point.x, y: point.y), NSPoint(x: point.x, y: point.y + 8), Tone.human.ns)
        let pennant = NSBezierPath()
        pennant.move(to: NSPoint(x: point.x, y: point.y))
        pennant.line(to: NSPoint(x: point.x + 5, y: point.y + 2))
        pennant.line(to: NSPoint(x: point.x, y: point.y + 4))
        pennant.close()
        Tone.human.ns.setFill(); pennant.fill()
    }
    private func hatch(_ rect: NSRect, clip: NSBezierPath) {
        let area = rect.intersection(bounds)
        guard area.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let path = NSBezierPath()
        var start = area.minX - rect.height
        while start < area.maxX {
            path.move(to: NSPoint(x: start, y: rect.maxY))
            path.line(to: NSPoint(x: start + rect.height, y: rect.minY))
            start += 5
        }
        Tone.machine.ns.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Separate handle rows keep both ends reachable even when their times coincide.
    private func badge(_ edge: CueEdge, at xx: CGFloat) -> NSRect {
        let width: CGFloat = 24
        let left = edge == .entry ? xx : xx - width
        return NSRect(x: min(max(0, left), bounds.width - width), y: edge == .entry ? 71 : 91,
                      width: width, height: 17)
    }

    private func drawPoint(_ edge: CueEdge, at time: Double) {
        guard let i = input, i.window.contains(time) else { return }
        let xx = x(time)
        line(.init(x: xx, y: 23), .init(x: xx, y: bounds.height), Tone.sound.ns)
        let rect = badge(edge, at: xx)
        Tone.sound.ns.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        text(edge == .entry ? "入" : "出", rect.insetBy(dx: 2, dy: 2), font: .systemFont(ofSize: 10, weight: .semibold),
             color: Tone.paper.ns, align: .center)
    }

    private func hitPoint(_ p: NSPoint, in i: WaveformView) -> CueEdge? {
        var nearest: CueEdge?
        var distance: CGFloat = 6
        for edge in CueEdge.allCases {
            guard let t = edge == .entry ? i.inPoint : i.outPoint, i.window.contains(t) else { continue }
            let xx = x(t)
            if badge(edge, at: xx).contains(p) { return edge }
            let d = abs(p.x - xx)
            if p.y >= 70, d < distance, !hits.contains(where: { $0.rect.contains(p) }) {
                nearest = edge; distance = d
            }
        }
        return nearest
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let i = input else { return }
        addCursorRect(rulerRect, cursor: .resizeLeftRight)
        for edge in CueEdge.allCases {
            if let t = edge == .entry ? i.inPoint : i.outPoint, i.window.contains(t) {
                addCursorRect(badge(edge, at: x(t)), cursor: .resizeLeftRight)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let i = input, bounds.width > 0 else { return }
        refreshCaches(i)
        let layout = laneLayout(i)
        Tone.paper.ns.setFill()
        bounds.fill()
        hits = []
        let sections = i.record.sections
        let showSections = i.visible.contains("section")
        // Alternate sections are tinted behind the waveform so structure reads without colour coding.
        if showSections {
            for (n, row) in sections.enumerated() where n % 2 == 1 {
                Tone.stripe.ns.setFill()
                NSRect(x: x(row.start), y: CanvasLayout.bandBottom, width: x(row.end) - x(row.start),
                       height: max(0, layout.lanesTop - CanvasLayout.bandBottom)).intersection(bounds).fill()
            }
        }
        for index in layout.visibleLanes {
            let top = layout.laneTop(index) - 1
            if index % 2 == 0 { Tone.stripe.ns.setFill(); NSRect(x: 0, y: top, width: bounds.width, height: CanvasLayout.laneStep).fill() }
        }
        if !layout.lanes.isEmpty {
            line(NSPoint(x: 0, y: layout.lanesTop), NSPoint(x: bounds.width, y: layout.lanesTop), Tone.rule.ns)
        }
        if layout.overflows { drawLaneScroller(layout) }
        drawRuler(i)
        if showSections { drawSections(i, sections) }
        drawWave(i, layout)
        drawMarks(i, layout)

        var entry = i.inPoint
        var exit = i.outPoint
        if movingPoint == nil, resizing == nil, let a = anchor, let b = dragTime {
            entry = min(a, b); exit = max(a, b)
        }
        if let entry, let exit {
            Tone.sound.ns.withAlphaComponent(0.12).setFill()
            NSRect(x: x(entry), y: CanvasLayout.bandTop, width: x(exit)-x(entry), height: bounds.height - CanvasLayout.bandTop).fill()
        }
        drawHover(i)
        if let entry { drawPoint(.entry, at: entry) }
        if let exit { drawPoint(.exit, at: exit) }
    }

    private func drawRuler(_ i: WaveformView) {
        let span = i.window.upperBound - i.window.lowerBound
        let labelFont = Typeface.digits(10)
        let grid = Tone.rule.ns.withAlphaComponent(0.7)
        if i.bars, downbeats.count > 1, let first = downbeats.first, let last = downbeats.last {
            let barSeconds = (last - first) / Double(downbeats.count - 1)
            let pixelsPerBar = barSeconds * Double(bounds.width) / span
            let step = [1, 2, 4, 8, 16, 32, 64, 128].first { Double($0) * pixelsPerBar > 44 } ?? 256
            for (n, t) in downbeats.enumerated() where i.window.contains(t) {
                let xx = x(t)
                if n % step == 0 {
                    line(.init(x: xx, y: 16), .init(x: xx, y: bounds.height), grid)
                    text(String(n + 1), NSRect(x: xx + 4, y: 6, width: 44, height: 14), font: labelFont, color: Tone.pencil.ns)
                } else if pixelsPerBar >= 6 {
                    line(.init(x: xx, y: 22), .init(x: xx, y: CanvasLayout.rulerHeight), Tone.rule.ns)
                }
            }
        } else {
            let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            let step: Double = steps.first(where: { $0 * Double(bounds.width) / span > 55 }) ?? 1200
            for t in stride(from: ceil(i.window.lowerBound/step)*step, through: i.window.upperBound, by: step) {
                let xx = x(t)
                line(.init(x: xx, y: 16), .init(x: xx, y: bounds.height), grid)
                text(rulerText(t, step: step), NSRect(x: xx + 4, y: 6, width: 65, height: 14), font: labelFont, color: Tone.pencil.ns)
            }
        }
        line(.init(x: 0, y: CanvasLayout.rulerHeight - 0.5), .init(x: bounds.width, y: CanvasLayout.rulerHeight - 0.5), Tone.rule.ns)
    }

    private func drawSections(_ i: WaveformView, _ sections: [Mark]) {
        for row in sections where x(row.end) >= 0 && x(row.start) < bounds.width {
            let frame = NSRect(x: x(row.start), y: CanvasLayout.bandTop, width: max(1, x(row.end)-x(row.start)),
                               height: CanvasLayout.bandBottom - CanvasLayout.bandTop)
            hits.append((frame, row))
            if row.id == i.selected {
                Tone.sound.ns.withAlphaComponent(0.12).setFill()
                frame.intersection(bounds).fill()
            }
            let inner = frame.intersection(bounds).insetBy(dx: 7, dy: 4)
            guard inner.width > 8 else { continue }
            let state = row.provenance
            var left = inner.minX
            if state == .confirmed { seal(at: NSPoint(x: left, y: inner.minY + 4)); left += 10 }
            if let letter = formLetters[row.id] {
                let font = Typeface.digits(10, weight: .medium)
                text(letter, NSRect(x: left, y: inner.minY + 2, width: 14, height: 14), font: font, color: Tone.pencil.ns)
                left += (letter as NSString).size(withAttributes: [.font: font]).width + 5
            }
            let nameRect = NSRect(x: left, y: inner.minY, width: inner.maxX - left, height: 18)
            let confirmed = state == .confirmed
            let ink = confirmed ? Tone.ink.ns : Tone.pencil.ns
            text(row.label, nameRect, font: Typeface.songtiNS(13, bold: confirmed),
                 color: state == .stale ? ink.withAlphaComponent(0.5) : ink, strike: state == .rejected)
            text(sectionSummaries[row.id] ?? "", NSRect(x: inner.minX, y: inner.minY + 19, width: inner.width, height: 14),
                 font: .systemFont(ofSize: 10), color: Tone.pencil.ns)
            if row.hasHint { flag(at: NSPoint(x: min(frame.maxX, bounds.width) - 9, y: frame.minY + 3)) }
        }
        // A boundary a person has listened to is inked; an unreviewed one stays a dashed suggestion.
        for n in sections.indices.dropFirst() {
            let t = sections[n].start
            guard i.window.contains(t) else { continue }
            let xx = x(t)
            let confirmed = sections[n].startConfirmed || sections[n-1].endConfirmed
            line(.init(x: xx, y: CanvasLayout.bandBottom), .init(x: xx, y: bounds.height), Tone.rule.ns)
            if confirmed {
                line(.init(x: xx, y: CanvasLayout.bandTop), .init(x: xx, y: CanvasLayout.bandBottom), Tone.ink.ns, width: 1.5)
            } else {
                line(.init(x: xx, y: CanvasLayout.bandTop), .init(x: xx, y: CanvasLayout.bandBottom), Tone.machine.ns, width: 1.5, dash: [3, 2])
            }
        }
    }

    private func drawWave(_ i: WaveformView, _ layout: CanvasLayout) {
        let mid = layout.waveMid
        let half = layout.waveHalf
        line(.init(x: 0, y: mid), .init(x: bounds.width, y: mid), Tone.rule.ns)
        let count = i.peaks.count
        guard count > 0, i.record.duration > 0 else { return }
        let span = i.window.upperBound - i.window.lowerBound
        let outer = NSBezierPath()
        let body = NSBezierPath()
        for col in 0..<Int(bounds.width) {
            let lo = min(count-1, max(0, Int((i.window.lowerBound+span*Double(col)/bounds.width)/i.record.duration*Double(count))))
            let hi = min(count, max(lo+1, Int((i.window.lowerBound+span*Double(col+1)/bounds.width)/i.record.duration*Double(count))))
            let slice = i.peaks[lo..<hi]
            let peak = CGFloat(slice.max() ?? 0)
            let mean = CGFloat(slice.reduce(0, +) / Float(slice.count))
            let xx = CGFloat(col) + 0.5
            let h = max(0.5, min(1, peak) * half)
            outer.move(to: .init(x: xx, y: mid - h)); outer.line(to: .init(x: xx, y: mid + h))
            let m = max(0.5, min(1, mean) * half)
            body.move(to: .init(x: xx, y: mid - m)); body.line(to: .init(x: xx, y: mid + m))
        }
        // The light outline is the peak envelope; the darker body is the mean of the peaks in each column.
        Tone.sound.ns.withAlphaComponent(0.35).setStroke(); outer.stroke()
        Tone.sound.ns.setStroke(); body.stroke()
    }

    private func drawMarks(_ i: WaveformView, _ layout: CanvasLayout) {
        let mid = layout.waveMid
        let half = layout.waveHalf
        let rows = i.record.marks.filter { row in
            let semanticEvent = row.kind == "insight" && row.fields["category"]?.value == "event" && row.id == i.selected
            return (row.analysisStale != true || row.reviewed) && (i.visible.contains(row.kind) || (i.visible.contains("event") && semanticEvent) || (row.kind == "rhythm_beat" && i.visible.contains("beat"))) && x(row.end) >= 0 && x(row.start) <= bounds.width
        }
        let pitches = rows.filter { $0.kind == "pitch" && $0.analysisStale != true }.compactMap { $0.metrics["midi_pitch"] }
        let pitchLow = floor(pitches.min() ?? 48)
        let pitchHigh = max(pitchLow + 12, ceil(pitches.max() ?? 84))
        if !pitches.isEmpty {
            text("旋律候选 · MIDI \(Int(pitchLow))–\(Int(pitchHigh))",
                 NSRect(x: bounds.width - 168, y: CanvasLayout.waveTop, width: 160, height: 14),
                 font: .systemFont(ofSize: 10), color: Tone.machine.ns, align: .right)
        }
        for row in rows {
            // Semantic findings often share an interval. Show the selected
            // finding's range; the list exposes every candidate without overlap.
            if row.kind == "insight" && row.id != i.selected { continue }
            let xx = x(row.start)
            let alpha = developAlpha(row.kind)
            if ["beat", "downbeat", "onset", "rhythm_beat"].contains(row.kind) {
                let length: CGFloat = row.kind == "downbeat" ? 22 : row.kind == "onset" ? 7 : 12
                let color = row.kind == "downbeat" ? Tone.ink.ns.withAlphaComponent(0.55 * alpha)
                    : Tone.pencil.ns.withAlphaComponent((row.kind == "onset" ? 0.3 : 0.45) * alpha)
                line(.init(x: xx, y: mid + half), .init(x: xx, y: mid + half - length), color)
            } else if row.kind == "pitch", row.analysisStale != true, let pitch = row.metrics["midi_pitch"] {
                let y = mid + half - (pitch - pitchLow)/(pitchHigh - pitchLow)*half*2
                line(.init(x: xx, y: y), .init(x: x(row.end), y: y), Tone.machine.ns.withAlphaComponent(alpha), width: 1.5)
            } else if let lane = layout.lanes.firstIndex(of: CanvasLayout.laneKey(row)) {
                // Lanes scrolled out of view are neither drawn nor hit-tested.
                guard layout.visibleLanes.contains(lane) else { continue }
                let width = max(row.kind == "note" && row.start == row.end ? 70 : 7, x(row.end)-xx)
                let box = NSRect(x: xx, y: layout.laneTop(lane), width: width, height: CanvasLayout.laneHeight)
                drawItem(row, in: box, selected: row.id == i.selected, alpha: alpha)
                hits.append((box, row))
                if row.kind == "emotion" {
                    for (key, dash) in [("valence", [CGFloat]()), ("arousal", [CGFloat(4), 3])] {
                        if let v = row.metrics[key] {
                            let yy = mid + half - (min(9, max(1, v))-1)/8 * 2*half
                            line(.init(x: xx, y: yy), .init(x: x(row.end), y: yy), Tone.machine.ns.withAlphaComponent(alpha),
                                 width: 1.5, dash: dash)
                        }
                    }
                }
            } else if row.kind == "acoustic", let v = row.metrics["rms"] {
                let yy = mid + half - min(1, v)*2*half
                line(.init(x: xx, y: yy), .init(x: x(row.end), y: yy), Tone.machine.ns.withAlphaComponent(0.8 * alpha))
            }
        }
    }

    /// Hue says who wrote it; the stroke says whether it is settled (see docs/ui-aesthetic-plan.md §4.2).
    private func drawItem(_ row: Mark, in rect: NSRect, selected: Bool, alpha: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let state = row.provenance
        context.setAlpha(alpha * (state == .stale ? 0.5 : 1))
        let shown = rect.intersection(bounds)
        if row.kind == "note" {
            if row.end > row.start { Tone.human.ns.withAlphaComponent(0.08).setFill(); shown.fill() }
            let ribbon = NSBezierPath()
            ribbon.move(to: NSPoint(x: rect.minX, y: rect.minY))
            ribbon.line(to: NSPoint(x: rect.minX + 6, y: rect.minY))
            ribbon.line(to: NSPoint(x: rect.minX + 6, y: rect.maxY))
            ribbon.line(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 4))
            ribbon.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            ribbon.close()
            Tone.human.ns.setFill(); ribbon.fill()
            if selected {
                Tone.sound.ns.setStroke()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
            }
            text(row.label, NSRect(x: max(rect.minX, 0) + 9, y: rect.minY + 3, width: shown.maxX - max(rect.minX, 0) - 11, height: 14),
                 font: .systemFont(ofSize: 10, weight: .medium), color: Tone.ink.ns)
            return
        }
        // At this scale a dashed box would read as a barcode, so draw a solid tick instead.
        if rect.width < 14 {
            let color: NSColor = switch state {
            case .confirmed, .cleared: Tone.ink.ns.withAlphaComponent(0.85)
            case .rejected: Tone.pencil.ns.withAlphaComponent(0.18)
            case .empty: Tone.rule.ns
            case .suggested, .stale: Tone.machine.ns.withAlphaComponent(0.45)
            }
            (selected ? Tone.sound.ns : color).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 6), xRadius: 1, yRadius: 1).fill()
            return
        }
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if selected { Tone.sound.ns.withAlphaComponent(0.14).setFill(); path.fill() }
        switch state {
        case .suggested:
            hatch(box, clip: path)
            path.setLineDash([4, 3], count: 2, phase: 0); Tone.machine.ns.setStroke()
        case .stale:
            hatch(box, clip: path)
            path.setLineDash([1.5, 2.5], count: 2, phase: 0); Tone.machine.ns.setStroke()
        case .rejected: Tone.pencil.ns.withAlphaComponent(0.35).setStroke()
        case .confirmed, .cleared: Tone.ink.ns.withAlphaComponent(0.7).setStroke()
        case .empty: Tone.rule.ns.setStroke()
        }
        if selected { Tone.sound.ns.setStroke() }
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
        var label = shown.insetBy(dx: 4, dy: 3)
        if state == .confirmed {
            seal(at: NSPoint(x: max(box.minX, 0) + 2, y: box.minY + 2))
            label.origin.x += 7; label.size.width -= 7
        }
        if state != .cleared && state != .empty {
            text(row.label, label, font: .systemFont(ofSize: 10, weight: state == .confirmed ? .semibold : .regular),
                 color: state == .confirmed ? Tone.ink.ns : Tone.pencil.ns, strike: state == .rejected)
        }
        if row.hasHint, box.maxX - 8 > 0 { flag(at: NSPoint(x: min(box.maxX, bounds.width) - 8, y: box.minY + 2)) }
    }

    private func laneLayout(_ i: WaveformView) -> CanvasLayout {
        CanvasLayout(record: i.record, visible: i.visible, hidden: i.hiddenLanes, selected: i.selected,
                     height: bounds.height, scroll: i.laneScroll)
    }

    /// A thin bar at the right edge shows which part of the lane list is in view.
    private func drawLaneScroller(_ layout: CanvasLayout) {
        let track = NSRect(x: bounds.width - 4, y: layout.lanesTop + 2, width: 3, height: bounds.height - 4 - layout.lanesTop - 2)
        guard track.height > 4 else { return }
        let total = CGFloat(layout.lanes.count)
        let thumb = NSRect(x: track.minX, y: track.minY + track.height * CGFloat(layout.firstLane) / total,
                           width: track.width, height: max(6, track.height * CGFloat(layout.visibleCount) / total))
        Tone.pencil.ns.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private var laneScrollRemainder: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = input else { return super.scrollWheel(with: event) }
        let layout = laneLayout(i)
        guard layout.overflows, p.y >= layout.lanesTop else {
            laneScrollRemainder = 0
            return super.scrollWheel(with: event)
        }
        // Precise (trackpad) deltas are in points; line deltas count rows directly.
        let rows = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / CanvasLayout.laneStep : event.scrollingDeltaY
        laneScrollRemainder -= rows
        let step = Int(laneScrollRemainder.rounded(.towardZero))
        guard step != 0 else { return }
        laneScrollRemainder -= CGFloat(step)
        let target = min(max(0, layout.firstLane + step), layout.lanes.count - layout.visibleCount)
        if target != layout.firstLane { i.onLaneScroll(target) }
    }

    private func drawHover(_ i: WaveformView) {
        guard let hx = hoverX, anchor == nil, hx >= 0, hx <= bounds.width else { return }
        line(.init(x: hx, y: CanvasLayout.rulerHeight), .init(x: hx, y: bounds.height), Tone.pencil.ns.withAlphaComponent(0.5),
             dash: [2, 2])
        let readout = hoverText(time(hx, snap: false), in: i)
        let font = Typeface.digits(10, weight: .medium)
        let width = (readout as NSString).size(withAttributes: [.font: font]).width + 12
        let left = hx + 6 + width > bounds.width ? hx - 6 - width : hx + 6
        let pill = NSRect(x: max(0, left), y: 4, width: width, height: 18)
        let shape = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
        Tone.paper.ns.setFill(); shape.fill()
        Tone.rule.ns.setStroke(); shape.stroke()
        text(readout, pill.insetBy(dx: 6, dy: 2), font: font, color: Tone.ink.ns)
    }

    private func hoverText(_ t: Double, in i: WaveformView) -> String {
        var parts = [clockText(t)]
        if let bar = downbeats.lastIndex(where: { $0 <= t }) {
            let beat = beats.filter { $0 >= downbeats[bar] - 0.01 && $0 <= t }.count
            parts.append("第 \(bar + 1) 小节" + (beat > 0 ? "第 \(beat) 拍" : ""))
        }
        if let section = i.record.sections.first(where: { $0.start <= t && t < $0.end }) { parts.append(section.label) }
        if let chord = i.record.marks.first(where: { $0.kind == "chord" && $0.analysisStale != true && $0.start <= t && t < $0.end }) {
            parts.append(chord.label)
        }
        return parts.joined(separator: "  ")
    }

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        anchor = time(p.x,snap: false); dragTime = nil; resizing = nil
        movingPoint = nil; picked = nil
        // Fix the gesture at mouse-down so crossing into the waveform cannot turn a seek into a selection.
        seeking = rulerRect.contains(p)
        if let i = input {
            if seeking { i.onSeek(time(p.x, snap: false)); return }
            movingPoint = hitPoint(p, in: i)
            if movingPoint != nil { return }
        }
        picked = hits.last(where: { $0.rect.contains(p) })?.row
        for hit in hits where hit.rect.insetBy(dx: -5,dy: 0).contains(p) {
            if hit.row.kind == "section", abs(p.x-x(hit.row.end)) <= 5, hit.row.end < (input?.record.duration ?? 0) {
                resizing = (hit.row.id,false); break
            }
            if hit.row.kind == "lyric" {
                if abs(p.x-x(hit.row.start)) <= 5 { resizing = (hit.row.id,true); break }
                if abs(p.x-x(hit.row.end)) <= 5 { resizing = (hit.row.id,false); break }
            }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if seeking {
            // Navigation stays continuous; beat snapping belongs to edits, as with a waveform click.
            input?.onSeek(time(convert(event.locationInWindow, from: nil).x, snap: false))
            return
        }
        let t = time(convert(event.locationInWindow, from: nil).x,snap: !event.modifierFlags.contains(.option))
        if let edge = movingPoint, let i = input {
            let limit = edge == .entry ? min(t, i.outPoint ?? t) : max(t, i.inPoint ?? t)
            i.onMovePoint(edge, limit)
        } else {
            dragTime = t
        }
        needsDisplay = true
        updatePlayhead()
    }
    override func mouseUp(with event: NSEvent) {
        defer {
            anchor=nil; dragTime=nil; resizing=nil; movingPoint=nil; picked=nil; seeking=false; needsDisplay=true
            updatePlayhead()
        }
        if seeking {
            input?.onSeek(time(convert(event.locationInWindow, from: nil).x, snap: false))
            return
        }
        if movingPoint != nil { return }
        guard let i = input, let a = anchor else { return }
        if let b = dragTime, let edge = resizing { i.onResize(edge.0,edge.1,b) }
        else if let b = dragTime, abs(x(a)-x(b)) > 3 { i.onRange(min(a,b)...max(a,b)) }
        else if let row = picked { i.onPick(row) }
        else { i.onSeek(a) }
    }
}

func clockText(_ t: Double) -> String {
    let hundredths = Int((max(0,t)*100).rounded())
    return String(format: "%02d:%02d.%02d", hundredths/6000, (hundredths/100)%60, hundredths%100)
}

/// Whole-second grid steps drop the hundredths that would always read ".00".
private func rulerText(_ t: Double, step: Double) -> String {
    guard step >= 1 else { return clockText(t) }
    let seconds = Int(t.rounded())
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
