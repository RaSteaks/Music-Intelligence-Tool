import SwiftUI

/// The preview uses the same time window as the detail view so it stays aligned at either end.
struct TimelineNavigator: View {
    @Binding var pan: Double
    let window: ClosedRange<Double>
    let duration: Double
    let peaks: [Float]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false
    @State private var showing = false
    @State private var dismissal: Task<Void, Never>?

    var body: some View {
        Slider(value: $pan, in: 0...1) { editing in
            dragging = editing
            reveal()
        }
        .accessibilityLabel("滚动时间轴")
        .accessibilityValue(clockText(window.lowerBound) + " 至 " + clockText(window.upperBound))
        .overlay(alignment: .top) {
            if showing {
                preview
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showing)
        .onChange(of: pan) { if !dragging { reveal() } }
        .onDisappear { dismissal?.cancel() }
    }

    private func reveal() {
        dismissal?.cancel()
        showing = true
        guard !dragging else { return }
        dismissal = Task {
            try? await Task.sleep(for: .milliseconds(550))
            if !Task.isCancelled { showing = false }
        }
    }

    private var preview: some View {
        VStack(spacing: 4) {
            HStack {
                Text("全曲定位")
                Spacer()
                Text(clockText(window.lowerBound) + " – " + clockText(window.upperBound))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.85))
            Canvas { context, size in
                let columns = max(1, Int(size.width))
                var wave = Path()
                let scale = (size.height / 2 - 1) / CGFloat(max(peaks.max() ?? 0, 0.01))
                for column in 0..<columns where !peaks.isEmpty {
                    let start = column * peaks.count / columns
                    let end = max(start + 1, (column + 1) * peaks.count / columns)
                    let h = max(0.5, CGFloat(peaks[start..<end].max() ?? 0) * scale)
                    let x = CGFloat(column) + 0.5
                    wave.move(to: CGPoint(x: x, y: size.height / 2 - h))
                    wave.addLine(to: CGPoint(x: x, y: size.height / 2 + h))
                }
                context.stroke(wave, with: .color(.mint.opacity(0.7)), lineWidth: 1)

                let left = size.width * window.lowerBound / duration
                let width = size.width * (window.upperBound - window.lowerBound) / duration
                let rect = CGRect(x: left, y: 0, width: width, height: size.height)
                let shape = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3)
                context.fill(shape, with: .color(.white.opacity(0.22)))
                context.stroke(shape, with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
            .frame(height: 30)
        }
        .padding(8)
        .background(Color(red: 0.09, green: 0.14, blue: 0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.18)) }
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
    }
}
