import AppKit
import SwiftUI

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

final class WaveCanvas: NSView {
    var input: WaveformView? {
        didSet {
            needsDisplay = true
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
    private var rulerRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: 27) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
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
    private let amber = NSColor(srgbRed: 0.96, green: 0.70, blue: 0.36, alpha: 1)
    private let aqua = NSColor(srgbRed: 0.40, green: 0.80, blue: 0.76, alpha: 1)
    private var summaryRevision: (track: String, revision: Int)?
    private var sectionSummaries: [String: String] = [:]
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
    private func line(_ a: NSPoint, _ b: NSPoint, _ color: NSColor) {
        color.setStroke()
        let path = NSBezierPath(); path.move(to: a); path.line(to: b); path.stroke()
    }
    private func label(_ text: String, _ rect: NSRect, _ color: NSColor, size: CGFloat = 10) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
                                                            .foregroundColor: color, .paragraphStyle: style])
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
        let tint = edge == .entry ? aqua : amber
        line(.init(x: xx, y: 23), .init(x: xx, y: bounds.height), tint)
        let rect = badge(edge, at: xx)
        tint.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        label(edge == .entry ? "入" : "出", rect.insetBy(dx: 6, dy: 1), .black, size: 11)
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
        // Playback redraws the cursor frequently; pitch frames must not force
        // every section aggregate to be recomputed on each display update.
        if summaryRevision?.track != i.record.trackID || summaryRevision?.revision != i.record.revision {
            sectionSummaries = Dictionary(uniqueKeysWithValues: i.record.sections.map { ($0.id, i.record.summary(for: $0)) })
            summaryRevision = (i.record.trackID, i.record.revision)
        }
        NSColor(srgbRed: 0.073, green: 0.107, blue: 0.124, alpha: 1).setFill()
        bounds.fill()
        hits = []
        let span = i.window.upperBound - i.window.lowerBound
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step: Double = steps.first(where: { $0 * Double(bounds.width) / span > 55 }) ?? 1200
        for t in stride(from: ceil(i.window.lowerBound/step)*step, through: i.window.upperBound, by: step) {
            let xx = x(t)
            line(.init(x: xx,y: 23), .init(x: xx,y: bounds.height), .white.withAlphaComponent(0.08))
            label(clockText(t), NSRect(x: xx+4,y: 6,width: 65,height: 16), .lightGray)
        }
        for row in i.record.sections where x(row.end) >= 0 && x(row.start) < bounds.width && i.visible.contains("section") {
            let frame = NSRect(x: x(row.start),y: 27,width: max(1,x(row.end)-x(row.start)),height: 40)
            let color = row.id == i.selected ? amber : aqua
            color.withAlphaComponent(0.15).setFill(); frame.insetBy(dx: 1,dy: 0).fill()
            let inner = frame.intersection(bounds).insetBy(dx: 6,dy: 3)
            label(row.label, inner, color, size: 12)
            label(sectionSummaries[row.id] ?? "", NSRect(x: inner.minX,y: 49,width: inner.width,height: 15), .lightGray)
            hits.append((frame,row))
        }
        let mid = bounds.height * 0.48
        let height = max(6, (bounds.height*0.34)-38)
        let path = NSBezierPath()
        let count = i.peaks.count
        if count > 0 {
            for col in 0..<Int(bounds.width) {
                let lo = min(count-1, max(0, Int((i.window.lowerBound+span*Double(col)/bounds.width)/i.record.duration*Double(count))))
                let hi = min(count, max(lo+1, Int((i.window.lowerBound+span*Double(col+1)/bounds.width)/i.record.duration*Double(count))))
                let amplitude = CGFloat(i.peaks[lo..<hi].max() ?? 0)
                let h = max(0.5, min(1, amplitude)*height)
                path.move(to: .init(x: CGFloat(col)+0.5,y: mid-h))
                path.line(to: .init(x: CGFloat(col)+0.5,y: mid+h))
            }
        }
        aqua.setStroke(); path.stroke()
        let rows = i.record.marks.filter { row in
            let semanticEvent = row.kind == "insight" && row.fields["category"]?.value == "event" && row.id == i.selected
            return (row.analysisStale != true || row.reviewed) && (i.visible.contains(row.kind) || (i.visible.contains("event") && semanticEvent) || (row.kind == "rhythm_beat" && i.visible.contains("beat"))) && x(row.end) >= 0 && x(row.start) <= bounds.width
        }
        let ordinary = ["lyric","word","note","chord","emotion","insight","tempo","repetition"].filter {
            i.visible.contains($0) || ($0 == "insight" && rows.contains { $0.kind == "insight" })
        }
        let eventTypes = Set(i.record.marks.filter { $0.kind == "event" }.compactMap { $0.fields["event_type"]?.value })
        let events = i.visible.contains("event") ? ["silence", "vocals", "drums", "bass"].filter { eventTypes.contains($0) }.map { "event:" + $0 } : []
        let intervalKinds = ordinary + events
        let pitches = rows.filter { $0.kind == "pitch" && $0.analysisStale != true }.compactMap { $0.metrics["midi_pitch"] }
        let pitchLow = floor(pitches.min() ?? 48)
        let pitchHigh = max(pitchLow + 12, ceil(pitches.max() ?? 84))
        if !pitches.isEmpty { label("旋律候选 · MIDI \(Int(pitchLow))–\(Int(pitchHigh))", NSRect(x: 8, y: 65, width: 220, height: 16), aqua) }
        for row in rows {
            // Semantic findings often share an interval. Show the selected
            // finding's range; the list exposes every candidate without overlap.
            if row.kind == "insight" && row.id != i.selected { continue }
            let xx = x(row.start)
            if ["beat","downbeat","onset","rhythm_beat"].contains(row.kind) {
                let color: NSColor = row.kind == "downbeat" ? amber : .white.withAlphaComponent(0.23)
                line(.init(x: xx,y: mid+height),.init(x: xx,y: mid+height-(row.kind == "downbeat" ? 32 : 12)),color)
            } else if row.kind == "pitch", row.analysisStale != true, let pitch = row.metrics["midi_pitch"] {
                let y = mid + height - (pitch - pitchLow)/(pitchHigh - pitchLow)*height*2
                line(.init(x: xx, y: y), .init(x: x(row.end), y: y), aqua)
            } else if ["lyric","word","note","chord","emotion","insight","event","tempo","repetition"].contains(row.kind) {
                let lane = row.kind == "event" ? "event:" + (row.fields["event_type"]?.value ?? "silence") : row.kind
                let dy = CGFloat(intervalKinds.firstIndex(of: lane) ?? 0)*21
                let width = max(row.kind == "note" && row.start == row.end ? 70 : 7, x(row.end)-xx)
                let box = NSRect(x: xx,y: bounds.height-22*CGFloat(intervalKinds.count)+dy,width: width,height: 19)
                let tint = row.id == i.selected ? amber : aqua
                tint.withAlphaComponent(0.15).setFill(); box.fill()
                label(row.label, box.insetBy(dx: 3,dy: 2), tint)
                hits.append((box,row))
                if row.kind == "emotion" {
                    for (key, color) in [("valence", aqua), ("arousal", amber)] {
                        if let v = row.metrics[key] {
                            let yy = mid + height - (min(9,max(1,v))-1)/8 * 2*height
                            line(.init(x: xx,y: yy),.init(x: x(row.end),y: yy),color)
                        }
                    }
                }
            } else if row.kind == "acoustic", let v = row.metrics["rms"] {
                let yy = mid+height - min(1,v)*2*height
                line(.init(x: xx,y: yy),.init(x: x(row.end),y: yy),amber)
            }
        }
        var entry = i.inPoint
        var exit = i.outPoint
        if movingPoint == nil, resizing == nil, let a = anchor, let b = dragTime {
            entry = min(a, b); exit = max(a, b)
        }
        if let entry, let exit {
            amber.withAlphaComponent(0.16).setFill()
            NSRect(x: x(entry),y: 24,width: x(exit)-x(entry),height: bounds.height-24).fill()
        }
        let head = resizing == nil ? i.cursor : (dragTime ?? i.cursor)
        line(.init(x: x(head),y: 20),.init(x: x(head),y: bounds.height),amber)
        let handle = NSBezierPath()
        handle.move(to: .init(x: x(head)-4, y: 20))
        handle.line(to: .init(x: x(head)+4, y: 20))
        handle.line(to: .init(x: x(head), y: 26))
        handle.close()
        amber.setFill(); handle.fill()
        if let entry { drawPoint(.entry, at: entry) }
        if let exit { drawPoint(.exit, at: exit) }
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
    }
    override func mouseUp(with event: NSEvent) {
        defer { anchor=nil; dragTime=nil; resizing=nil; movingPoint=nil; picked=nil; seeking=false; needsDisplay=true }
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
