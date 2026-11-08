import SwiftUI

/// A record drawn as a vinyl disc: 12 o'clock is 0 s and time runs clockwise.
/// Outer ring: sections. Radial bars: short-term loudness. Inner amber line: valence.
/// Vermilion ticks at the rim: human notes. Colours are fixed so a record always renders the same image.
struct RecordPortrait: View {
    let record: SongRecord
    let size: CGFloat

    private static let disc = Color(red: 0x17 / 255, green: 0x20 / 255, blue: 0x2A / 255)
    private static let groove = Color(red: 0x2A / 255, green: 0x32 / 255, blue: 0x3C / 255)
    private static let sound = Color(red: 0x5C / 255, green: 0xC8 / 255, blue: 0xBE / 255)
    private static let machine = Color(red: 0xEB / 255, green: 0xB1 / 255, blue: 0x5C / 255)
    private static let humanLabel = Color(red: 0xC2 / 255, green: 0x3E / 255, blue: 0x2A / 255)
    private static let humanTick = Color(red: 0xF2 / 255, green: 0x73 / 255, blue: 0x5A / 255)
    private static let inked = Color(red: 0xE9 / 255, green: 0xEE / 255, blue: 0xF2 / 255)
    private static let pencil = Color(red: 0x8E / 255, green: 0x99 / 255, blue: 0xA6 / 255)

    private var title: String { URL(fileURLWithPath: record.path).deletingPathExtension().lastPathComponent }

    var body: some View {
        Canvas { context, canvas in
            draw(in: &context, size: canvas)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("唱片肖像")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let sections = record.sections
        let confirmed = sections.filter { $0.provenance == .confirmed }.count
        return "\(title)，\(sections.count) 个段落，已确认 \(confirmed) 个"
    }

    private func angle(_ t: Double) -> Double {
        -Double.pi / 2 + 2 * Double.pi * t / max(record.duration, 0.001)
    }
    private func point(_ c: CGPoint, _ radius: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + radius * CGFloat(cos(a)), y: c.y + radius * CGFloat(sin(a)))
    }

    private func draw(in context: inout GraphicsContext, size canvas: CGSize) {
        let r = min(canvas.width, canvas.height) / 2
        let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let detailed = size >= 60
        context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Self.disc))

        if detailed {
            for f in stride(from: 0.84, to: 0.44, by: -0.08) {
                let rr = r * CGFloat(f)
                context.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(Self.groove), lineWidth: 0.5)
            }
            drawLoudness(in: &context, c: c, r: r)
            drawValence(in: &context, c: c, r: r)
        }
        drawSections(in: &context, c: c, r: r)
        if detailed { drawNotes(in: &context, c: c, r: r) }

        let label = r * (detailed ? 0.3 : 0.36)
        context.fill(Path(ellipseIn: CGRect(x: c.x - label, y: c.y - label, width: 2 * label, height: 2 * label)),
                     with: .color(Self.humanLabel))
        if size >= 120 {
            let details = [record.key, record.bpm.map { String(format: "%.0f BPM", $0) }].compactMap { $0 }.joined(separator: "  ")
            context.draw(Text(title).font(Typeface.songti(max(9, size * 0.055), bold: true)).foregroundStyle(.white),
                         in: CGRect(x: c.x - label * 0.8, y: c.y - label * 0.5, width: label * 1.6, height: label * 0.55))
            if !details.isEmpty {
                context.draw(Text(details).font(.system(size: max(7, size * 0.032)).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.8)),
                             at: CGPoint(x: c.x, y: c.y + label * 0.42))
            }
        }
        let hole = max(1.2, r * 0.035)
        context.fill(Path(ellipseIn: CGRect(x: c.x - hole, y: c.y - hole, width: 2 * hole, height: 2 * hole)),
                     with: .color(Self.disc))
    }

    private func drawSections(in context: inout GraphicsContext, c: CGPoint, r: CGFloat) {
        let ring = r * 0.92
        let width = max(1.5, r * 0.07)
        let maxGap = record.sections.count > 1 ? 0.012 : 0
        for row in record.sections where row.end > row.start {
            let a = angle(row.start), b = angle(row.end)
            // The gap shrinks with short sections so the end angle never passes the start, which would draw a full turn.
            let gap = min(maxGap, (b - a) * 0.25)
            guard b - 2 * gap > a else { continue }
            var arc = Path()
            arc.addArc(center: c, radius: ring, startAngle: .radians(a + gap), endAngle: .radians(b - gap), clockwise: false)
            let confirmed = row.provenance == .confirmed
            context.stroke(arc, with: .color(confirmed ? Self.inked.opacity(0.85) : Self.pencil.opacity(0.75)),
                           style: StrokeStyle(lineWidth: width, lineCap: .butt, dash: confirmed ? [] : [max(1.5, width * 0.6), max(1, width * 0.4)]))
        }
    }

    private func drawLoudness(in context: inout GraphicsContext, c: CGPoint, r: CGFloat) {
        let rows = record.marks.filter { $0.kind == "acoustic" && $0.analysisStale != true }
        let values = rows.compactMap { row in row.metrics["short_lufs"].map { (row.start, row.end, $0) } }
        guard !values.isEmpty, record.duration > 0 else { return }
        let bins = min(180, max(24, Int(record.duration)))
        var levels = [Double?](repeating: nil, count: bins)
        for (start, end, lufs) in values {
            let a = max(0, Int(start / record.duration * Double(bins)))
            let b = min(bins - 1, Int(end / record.duration * Double(bins)))
            guard a <= b else { continue }
            for n in a...b { levels[n] = max(levels[n] ?? -100, lufs) }
        }
        let inner = r * 0.36
        let outer = r * 0.84
        var bars = Path()
        for (n, level) in levels.enumerated() {
            guard let level else { continue }
            let amount = CGFloat(min(1, max(0, (level + 40) / 34)))
            let a = angle((Double(n) + 0.5) / Double(bins) * record.duration)
            bars.move(to: point(c, inner, a))
            bars.addLine(to: point(c, inner + (outer - inner) * max(0.05, amount), a))
        }
        context.stroke(bars, with: .color(Self.sound.opacity(0.9)), style: StrokeStyle(lineWidth: max(0.8, r * 0.012), lineCap: .round))
    }

    private func drawValence(in context: inout GraphicsContext, c: CGPoint, r: CGFloat) {
        let rows = record.marks.filter { $0.kind == "emotion" && $0.analysisStale != true && $0.metrics["valence"] != nil }
            .sorted { $0.start < $1.start }
        guard rows.count > 1 else { return }
        var line = Path()
        for (n, row) in rows.enumerated() {
            let v = min(9, max(1, row.metrics["valence"] ?? 5))
            let radius = r * (0.4 + CGFloat((v - 5) / 4) * 0.035)
            let p = point(c, radius, angle((row.start + row.end) / 2))
            if n == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.stroke(line, with: .color(Self.machine), lineWidth: max(1, r * 0.015))
    }

    private func drawNotes(in context: inout GraphicsContext, c: CGPoint, r: CGFloat) {
        var ticks = Path()
        for row in record.marks where row.kind == "note" {
            let a = angle(row.start)
            ticks.move(to: point(c, r * 0.965, a))
            ticks.addLine(to: point(c, r, a))
        }
        context.stroke(ticks, with: .color(Self.humanTick), lineWidth: max(1, r * 0.02))
    }
}
