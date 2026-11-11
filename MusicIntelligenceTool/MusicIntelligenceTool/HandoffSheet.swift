import SwiftUI

/// The preview, JSON, copy, and send actions all use the revision captured when the sheet opened.
struct HandoffSheet: View {
    let studio: Studio
    let song: SongRecord
    let onCopy: () -> Bool
    let onExported: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = "section"

    var body: some View {
        let groups = CatalogCategory.all.map { (category: $0, items: CatalogCategory.items($0.id, in: song)) }
            .filter { !$0.items.isEmpty }
        // Insights may also appear in Events and Model Comparisons. Count each saved record once.
        let records = Dictionary(groups.flatMap(\.items).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let confirmed = records.filter { $0.reviewStatus == .confirmed }.count
        let pending = records.filter { $0.reviewStatus.needsReview }.count
        let rejected = records.count - confirmed - pending
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RecordPortrait(record: song, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("导出与分享").font(.title2.weight(.semibold))
                    Text(URL(fileURLWithPath: song.path).deletingPathExtension().lastPathComponent)
                        .font(Typeface.songti(15, bold: true)).lineLimit(2)
                }
                Spacer()
                Text("第 \(song.revision) 版 · \(durationText(song.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("目录条目 · 已确认 \(confirmed) · 待核对 \(pending) · 已拒绝 \(rejected)")
                .font(.callout.monospacedDigit()).accessibilityIdentifier("deliveryReviewCounts")
            HStack {
                Picker("预览内容", selection: $category) {
                    ForEach(groups, id: \.category.id) { group in
                        Text("\(group.category.title) · \(group.items.count) 条").tag(group.category.id)
                    }
                }
                .fixedSize().accessibilityIdentifier("deliveryCategory")
                Spacer()
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    let items = groups.first { $0.category.id == category }?.items ?? groups.first?.items ?? []
                    ForEach(items) { row in
                        preview(row)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("deliveryPreview")
            Divider()
            Text("导出和分享包含本版完整记录，包括尚待核对的内容与分析来源。发送使用本机 Claude Code Channel。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("关闭", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button("复制交接文本") { if onCopy() { dismiss() } }
                Button("发送给 Claude Code") {
                    Task { await studio.sendToAgent(song) }
                    dismiss()
                }
                .disabled(studio.sendingToAgent)
                .accessibilityIdentifier("sendToAgent")
                Button("导出 JSON…") {
                    if let url = studio.exportJSON(song) {
                        onExported(url)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("exportJSON")
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 560, height: 450)
    }

    private func preview(_ row: Mark) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(timeRangeText(row.timeRange)) · \(row.reviewStatus.title)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(row.displayName).font(.callout.weight(.medium)).textSelection(.enabled)
            let detail = row.kind == "section" ? song.summary(for: row) : row.fields["content"]?.value ?? ""
            if !detail.isEmpty && detail != row.displayName {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("deliveryItem-\(row.id)")
    }
}
