import SwiftUI

/// A permanent whole-song strip while zoomed in. Dragging the viewport scrolls the detail view;
/// clicking elsewhere centres the viewport there.
struct TimelineNavigator: View {
    @Binding var pan: Double
    let window: ClosedRange<Double>
    let duration: Double
    let peaks: [Float]
    @State private var grab: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let viewport = viewportRect(width: width, height: geometry.size.height)
            Canvas { context, size in
                let columns = max(1, Int(size.width))
                var wave = Path()
                let scale = (size.height / 2 - 2) / CGFloat(max(peaks.max() ?? 0, 0.01))
                for column in 0..<columns where !peaks.isEmpty {
                    let start = column * peaks.count / columns
                    let end = max(start + 1, (column + 1) * peaks.count / columns)
                    let h = max(0.5, CGFloat(peaks[start..<end].max() ?? 0) * scale)
                    let x = CGFloat(column) + 0.5
                    wave.move(to: CGPoint(x: x, y: size.height / 2 - h))
                    wave.addLine(to: CGPoint(x: x, y: size.height / 2 + h))
                }
                context.stroke(wave, with: .color(Tone.sound.color.opacity(0.55)), lineWidth: 1)
                let shape = Path(roundedRect: viewport.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3)
                context.fill(shape, with: .color(Tone.sound.color.opacity(0.12)))
                context.stroke(shape, with: .color(Tone.ink.color.opacity(0.75)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if grab == nil {
                    grab = viewport.contains(value.startLocation) ? value.startLocation.x - viewport.minX : viewport.width / 2
                }
                let travel = max(1, width - viewport.width)
                pan = min(1, max(0, (value.location.x - (grab ?? 0)) / travel))
            }.onEnded { _ in grab = nil })
        }
        .frame(height: 24)
        .background(Tone.paper.color, in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Tone.rule.color) }
        .help("拖动视口框滚动时间轴，点击其他位置跳到该处")
        .accessibilityRepresentation {
            Slider(value: $pan, in: 0...1) { Text("滚动时间轴") }
        }
        .accessibilityValue(clockText(window.lowerBound) + " 至 " + clockText(window.upperBound))
    }

    private func viewportRect(width: CGFloat, height: CGFloat) -> CGRect {
        guard duration > 0 else { return .zero }
        let left = width * window.lowerBound / duration
        let span = max(6, width * (window.upperBound - window.lowerBound) / duration)
        return CGRect(x: left, y: 0, width: span, height: height)
    }
}
