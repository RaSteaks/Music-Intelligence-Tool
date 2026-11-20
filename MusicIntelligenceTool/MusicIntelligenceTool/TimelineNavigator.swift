import SwiftUI

/// A permanent whole-song strip while zoomed in. Dragging the viewport scrolls the detail view;
/// clicking elsewhere centres the viewport there. Dragging the handle on its top edge changes its height.
struct TimelineNavigator: View {
    static let defaultHeight = 24.0
    static let heightRange = 24.0...160.0
    /// The handle fills the gap between the timeline and the strip, so it never competes with the viewport drag.
    static let handleHeight: CGFloat = 8

    @Binding var pan: Double
    @Binding var height: Double
    let window: ClosedRange<Double>
    let duration: Double
    let peaks: [Float]
    /// Read only by `NavigatorPlayhead`, so playback redraws the red line rather than the whole strip.
    let studio: Studio
    @AppStorage(WavePalette.preference) private var palette = WavePalette.teal
    @State private var grab: CGFloat?
    @State private var resizeStart: Double?
    @State private var handleHovered = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let viewport = viewportRect(width: width, height: geometry.size.height)
            NavigatorWaveform(peaks: peaks, palette: palette)
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Tone.sound.color.opacity(0.12))
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Tone.ink.color.opacity(0.75), lineWidth: 1) }
                        .frame(width: viewport.width, height: viewport.height)
                        .offset(x: viewport.minX)
                }
                .overlay(alignment: .topLeading) { NavigatorPlayhead(studio: studio, duration: duration, width: width) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if grab == nil {
                        grab = viewport.contains(value.startLocation) ? value.startLocation.x - viewport.minX : viewport.width / 2
                    }
                    let travel = max(1, width - viewport.width)
                    pan = min(1, max(0, (value.location.x - (grab ?? 0)) / travel))
                }.onEnded { _ in grab = nil })
        }
        // A short window may squeeze the strip back toward its minimum; the timeline keeps its own minimum height.
        .frame(minHeight: Self.heightRange.lowerBound, maxHeight: height)
        .background(Tone.paper.color, in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Tone.rule.color) }
        .help("拖动视口框滚动时间轴，点击其他位置跳到该处")
        .accessibilityRepresentation {
            Slider(value: $pan, in: 0...1) { Text("滚动时间轴") }
        }
        .accessibilityValue(clockText(window.lowerBound) + " 至 " + clockText(window.upperBound))
        .overlay(alignment: .top) { resizeHandle.offset(y: -Self.handleHeight) }
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(handleHovered || resizeStart != nil ? Tone.pencil.color : Tone.rule.color)
            .frame(width: 32, height: 3)
            .frame(maxWidth: .infinity)
            .frame(height: Self.handleHeight)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .onHover { handleHovered = $0 }
            .onTapGesture(count: 2) { height = Self.defaultHeight }
            // Global coordinates: the handle itself moves while the strip grows, which would skew a local translation.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                let start = resizeStart ?? height
                resizeStart = start
                height = clampedHeight(start - value.translation.height)
            }.onEnded { _ in resizeStart = nil })
            .help("上下拖动调整概览波形高度，双击恢复默认")
            .accessibilityElement()
            .accessibilityLabel("概览波形高度")
            .accessibilityValue("\(Int(height)) 点")
            .accessibilityAdjustableAction { direction in
                height = clampedHeight(height + (direction == .increment ? 8 : -8))
            }
    }

    private func clampedHeight(_ value: Double) -> Double {
        min(Self.heightRange.upperBound, max(Self.heightRange.lowerBound, value))
    }

    private func viewportRect(width: CGFloat, height: CGFloat) -> CGRect {
        guard duration > 0 else { return .zero }
        let left = width * window.lowerBound / duration
        let span = max(6, width * (window.upperBound - window.lowerBound) / duration)
        return CGRect(x: left, y: 0, width: span, height: height)
    }
}

/// The whole-song envelope stays fixed while its viewport moves.
private struct NavigatorWaveform: View {
    let peaks: [Float]
    let palette: WavePalette

    var body: some View {
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
            context.stroke(wave, with: .color(Color(nsColor: palette.edge).opacity(0.55)), lineWidth: 1)
        }
    }
}

/// A red vertical line at the current playback position across the whole-song strip.
private struct NavigatorPlayhead: View {
    let studio: Studio
    let duration: Double
    let width: CGFloat

    var body: some View {
        if duration > 0 {
            let x = width * CGFloat(min(1, max(0, studio.cursor / duration)))
            Rectangle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: 1.5)
                .frame(maxHeight: .infinity)
                .offset(x: x - 0.75)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
