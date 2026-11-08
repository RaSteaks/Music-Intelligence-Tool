import AppKit
import QuartzCore
import SwiftUI

/// Playback, cue points, listening options and quick marking in one row below the canvas.
/// It wraps onto two rows when the detail column is narrow.
struct TransportBar: View {
    @Bindable var studio: Studio
    let song: SongRecord
    let inShortcut: String
    let outShortcut: String
    let onAdd: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                playback
                cuePoints
                Spacer(minLength: 8)
                listening
                marking
                zoom
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    playback
                    Spacer(minLength: 8)
                    cuePoints
                }
                HStack(spacing: 10) {
                    listening
                    Spacer(minLength: 8)
                    marking
                    zoom
                }
            }
        }
        .controlSize(.small)
    }

    private var playback: some View {
        HStack(spacing: 8) {
            Button { studio.togglePlayback() } label: {
                Image(systemName: studio.playing ? "pause.fill" : "play.fill").frame(width: 14)
            }
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel("播放或暂停")
            PlayheadClock(studio: studio)
            Text("/ " + clockText(song.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var cuePoints: some View {
        Menu {
            Button("标记入点（" + inShortcut.uppercased() + "）") { studio.markPoint(.entry) }
            Button("标记出点（" + outShortcut.uppercased() + "）") { studio.markPoint(.exit) }
            Button("清除出入点") { studio.selection = nil }
                .disabled(studio.inPoint == nil && studio.outPoint == nil)
        } label: {
            Text(pointReadout).font(.caption.monospacedDigit()).lineLimit(1)
        }
        .fixedSize()
        .accessibilityLabel("出入点")
        .accessibilityValue(pointReadout)
        .accessibilityIdentifier("cuePoints")
    }

    private var listening: some View {
        HStack(spacing: 8) {
            Toggle("循环", isOn: $studio.loop).toggleStyle(.button)
            Picker("音轨", selection: Binding(get: { studio.stem }, set: studio.chooseStem)) {
                ForEach(["原曲"] + song.stems.keys.sorted(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
            Toggle("吸附", isOn: $studio.snap).toggleStyle(.button)
                .accessibilityLabel("吸附拍点")
                .help("拖动编辑时吸附到最近的拍点；按住 Option 临时关闭")
        }
    }

    private var marking: some View {
        HStack(spacing: 4) {
            Button("分段", systemImage: "scissors") { onAdd("section") }
                .help("在出入点处分段")
            Button("加注释", systemImage: "bookmark") { onAdd("note") }
                .help("在出入点或播放头处加注释")
            Button("加歌词", systemImage: "text.quote") { onAdd("lyric") }
                .help("在出入点处加一句歌词")
        }
        .labelStyle(.iconOnly)
    }

    private var zoom: some View {
        HStack(spacing: 4) {
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $studio.zoom, in: 1...24).frame(width: 80).accessibilityLabel("时间轴缩放")
        }
    }

    private var pointReadout: String {
        if studio.inPoint == nil && studio.outPoint == nil { return "出入点" }
        return "入 " + (studio.inPoint.map(clockText) ?? "—") + "   出 " + (studio.outPoint.map(clockText) ?? "—")
    }
}

/// Minutes and seconds large and light, hundredths smaller. Only this view follows the playhead every frame.
private struct PlayheadClock: View {
    let studio: Studio

    var body: some View {
        let text = clockText(studio.cursor)
        let dot = text.lastIndex(of: ".") ?? text.endIndex
        (Text(text[..<dot]).font(.system(size: 17, weight: .light).monospacedDigit())
            + Text(text[dot...]).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary))
            .fixedSize()
            .accessibilityIdentifier("playheadTime")
    }
}

/// Advances playback state once per display refresh while playing.
/// A slow timer keeps loop wrap-around working when the window is hidden and the display link pauses.
struct PlaybackClock: NSViewRepresentable {
    let studio: Studio
    let playing: Bool

    func makeNSView(context: Context) -> ClockView { ClockView() }
    func updateNSView(_ view: ClockView, context: Context) {
        view.onFrame = { studio.tick() }
        view.running = playing
    }

    final class ClockView: NSView {
        var onFrame: (() -> Void)?
        var running = false {
            didSet { if running != oldValue { reschedule() } }
        }
        private var link: CADisplayLink?
        private var fallback: Timer?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reschedule()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func reschedule() {
            link?.invalidate(); link = nil
            fallback?.invalidate(); fallback = nil
            guard running, window != nil else { return }
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
            fallback = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFrame?() }
            }
        }
        @objc private func step(_ link: CADisplayLink) { onFrame?() }
    }
}
