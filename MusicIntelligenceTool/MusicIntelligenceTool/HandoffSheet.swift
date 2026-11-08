import SwiftUI

/// Shows what the agent will receive before anything is sent. `song` is a snapshot taken when the preview
/// opened; sending and copying use the same snapshot, so the card never describes a different revision.
struct HandoffSheet: View {
    let studio: Studio
    let song: SongRecord
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var fields: [(mark: Mark, field: ReviewedText)] {
        song.marks.flatMap { mark in mark.fields.values.map { (mark, $0) } }
    }
    private var confirmed: Int { fields.filter { $0.field.confirmed != nil }.count }
    private var suggested: Int {
        fields.filter { $0.field.confirmed == nil && $0.field.suggested != nil && $0.field.suggestionAvailable && $0.mark.analysisStale != true }.count
    }
    private var hints: Int { fields.filter { $0.field.hasHint }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 24) {
                RecordPortrait(record: song, size: 160)
                VStack(alignment: .leading, spacing: 10) {
                    Text("交给 agent").font(.title2.weight(.semibold))
                    Text(URL(fileURLWithPath: song.path).deletingPathExtension().lastPathComponent)
                        .font(Typeface.songti(15, bold: true))
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        row("修订", "第 \(song.revision) 版")
                        row("已确认", "\(confirmed) 项")
                        row("仍为建议", "\(suggested) 项")
                        row("提示", "\(hints) 条")
                        row("接收方", "Claude Code Channel")
                    }
                    .font(.callout)
                    Text("发送和复制的都是打开预览时的这一版记录。之后的修改不会进入这次交接。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("复制交接文本") { onCopy(); dismiss() }
                    .help("复制完整分析记录和 MCP 查询指令，可以手动粘贴给 agent")
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("发送") {
                    Task { await studio.sendToAgent(song) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(studio.sendingToAgent)
                .accessibilityIdentifier("sendToAgent")
                .help("将当前歌曲的完整分析记录发送给 Claude Code")
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
