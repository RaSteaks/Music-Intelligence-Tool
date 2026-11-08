import AppKit
import SwiftUI

/// Hue says who produced something; stroke (see `Provenance`) says whether it is settled.
/// Sound is listening material, machine is model output, human is written into the record.
enum Tone: String {
    case sound = "ToneSound", machine = "ToneMachine", human = "ToneHuman"
    case paper = "TonePaper", stripe = "ToneStripe", rule = "ToneRule", pencil = "TonePencil", ink = "ToneInk"

    var color: Color { Color(rawValue) }
    var ns: NSColor { NSColor(named: rawValue) ?? .labelColor }
}

enum Typeface {
    /// Songti is reserved for the work itself: titles, section names and lyrics.
    static func songti(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size)
    }
    static func songtiNS(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular", size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }
    static func digits(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

/// The review state of a field or mark, drawn the same way on the canvas, in lists and on the card.
enum Provenance: Equatable {
    case suggested, confirmed, cleared, rejected, stale, empty

    var title: String {
        switch self {
        case .suggested: "建议"
        case .confirmed: "已确认"
        case .cleared: "已清空"
        case .rejected: "已拒绝"
        case .stale: "待更新"
        case .empty: "未填写"
        }
    }
}

extension ReviewedText {
    var provenance: Provenance {
        if let confirmed { return confirmed.isEmpty ? .cleared : .confirmed }
        if suggested == nil { return .empty }
        if origin?.stale == true { return .stale }
        if rejected == true { return .rejected }
        return .suggested
    }
    var hasHint: Bool { hint?.isEmpty == false }
}

extension Mark {
    /// Canvas and list state follow the label field; other fields are reviewed on the card.
    var provenance: Provenance {
        let field = fields["label"]
        // Same rule as the card's field state: an empty confirmed value is a deliberate clear,
        // while a label slot with neither value nor suggestion has never been filled.
        if let confirmed = field?.confirmed { return confirmed.isEmpty ? .cleared : .confirmed }
        let blank = field != nil && field?.suggested == nil
        if source == "user" { return blank ? .empty : .confirmed }
        if analysisStale == true { return .stale }
        if blank { return .empty }
        if let field, field.suggested != nil { return field.provenance }
        return .suggested
    }
    var hasHint: Bool { fields.values.contains(where: \.hasHint) }
    var accessibilityState: String {
        provenance.title + (hasHint ? "，有提示" : "")
    }
}

/// The 6pt vermilion square that marks human confirmation.
struct Seal: View {
    var size: CGFloat = 6
    var body: some View {
        Rectangle().fill(Tone.human.color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Compact glyph used in lists. Every glyph is paired with a text label for VoiceOver.
struct ProvenanceGlyph: View {
    let state: Provenance
    var hint = false

    var body: some View {
        HStack(spacing: 3) {
            Group {
                switch state {
                case .confirmed: Seal(size: 7)
                case .suggested:
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Tone.machine.color, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                case .stale:
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Tone.machine.color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [0.8, 1.6]))
                case .rejected:
                    Rectangle().fill(Tone.pencil.color.opacity(0.6)).frame(height: 1)
                case .cleared:
                    Rectangle().strokeBorder(Tone.ink.color.opacity(0.7), lineWidth: 1)
                case .empty:
                    Rectangle().strokeBorder(Tone.rule.color, lineWidth: 1)
                }
            }
            .frame(width: 9, height: 9)
            if hint {
                Image(systemName: "flag.fill").font(.system(size: 7)).foregroundStyle(Tone.human.color)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(state.title + (hint ? "，有提示" : ""))
    }
}

/// A vinyl outline shared by the empty stage and the drop target.
struct VinylOutline: View {
    var lineColor = Tone.rule.color
    var body: some View {
        Canvas { context, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func ring(_ f: CGFloat, _ width: CGFloat, _ opacity: Double) {
                let rect = CGRect(x: c.x - r * f, y: c.y - r * f, width: 2 * r * f, height: 2 * r * f)
                context.stroke(Path(ellipseIn: rect), with: .color(lineColor.opacity(opacity)), lineWidth: width)
            }
            ring(0.98, 1.5, 1)
            for f in stride(from: 0.88, to: 0.42, by: -0.09) { ring(f, 0.75, 0.55) }
            ring(0.3, 1.5, 1)
            ring(0.04, 1, 1)
        }
        .accessibilityHidden(true)
    }
}
