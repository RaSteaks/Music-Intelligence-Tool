import SwiftUI

struct ReviewInspector: View {
    let studio: Studio
    let song: SongRecord
    let row: Mark
    let items: [Mark]
    let filter: CatalogFilter
    @Binding var autoAudition: Bool
    let onSelect: (Mark) -> Void
    let onPending: (Mark) -> Void
    @State private var editor: ReviewEditor?
    @State private var timeDraft = false

    var body: some View {
        let index = items.firstIndex { $0.id == row.id } ?? items.endIndex
        let before = items.prefix(index)
        let after = items.dropFirst(min(index + 1, items.count))
        let previous = before.last(where: filter.includes)
        let next = after.first(where: filter.includes)
        // At the end of the list, continue with unresolved items above the current one.
        let pending = after.first { $0.reviewStatus.needsReview } ?? before.first { $0.reviewStatus.needsReview }
        VStack(spacing: 0) {
            controls(previous: previous, next: next, pending: pending)
            Divider()
            ScrollView {
                ReviewCard(studio: studio, song: song, row: row, editor: $editor, timeDraft: $timeDraft,
                           onAdvance: next.map { item in { onSelect(item) } }, onSelect: onSelect)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func controls(previous: Mark?, next: Mark?, pending: Mark?) -> some View {
        let hasDraft = editor != nil || timeDraft
        return VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button("上一条", systemImage: "chevron.left") { if let previous { onSelect(previous) } }
                    .labelStyle(.iconOnly).disabled(previous == nil || hasDraft).help("上一条")
                    .accessibilityIdentifier("previousRecord")
                Spacer(minLength: 0)
                Button(studio.auditionRange == row.timeRange ? "再听一次" : "试听本条", systemImage: "repeat") {
                    studio.audition(row.timeRange)
                }
                .disabled(row.start == row.end)
                .accessibilityIdentifier("auditionRecord")
                Spacer(minLength: 0)
                Button("下一条", systemImage: "chevron.right") { if let next { onSelect(next) } }
                    .labelStyle(.iconOnly).disabled(next == nil || hasDraft).help("下一条")
                    .accessibilityIdentifier("nextRecord")
            }
            HStack {
                Button("下一条待核对", systemImage: "list.bullet") { if let pending { onPending(pending) } }
                    .disabled(pending == nil || hasDraft)
                    .accessibilityIdentifier("nextPendingRecord")
                Spacer(minLength: 0)
                Menu {
                    Toggle("切换条目后自动试听", isOn: $autoAudition)
                } label: {
                    Label("试听设置", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("试听设置")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help(hasDraft ? "先保存或取消当前修改，再切换条目" : "按当前列表顺序校对条目")
    }
}

struct SegmentOverview: View {
    let song: SongRecord
    let section: Mark
    let onSelect: (Mark) -> Void

    var body: some View {
        let groups = ["lyric", "emotion", "event", "note"].map { kind in
            (kind: kind, items: CatalogCategory.items(kind, in: song).filter { $0.overlaps(section.start..<section.end) })
        }.filter { !$0.items.isEmpty }
        let summary = song.summary(for: section)
        VStack(alignment: .leading, spacing: 8) {
            Text("片段概览").font(.headline).accessibilityAddTraits(.isHeader)
            if !summary.isEmpty { Text(summary).font(.callout).textSelection(.enabled) }
            if groups.isEmpty {
                Text("此段还没有歌词、情绪、事件或注释。").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.kind) { group in
                RelatedRecords(title: CatalogCategory.title(group.kind), items: group.items, onSelect: onSelect)
            }
        }
        .accessibilityIdentifier("segmentOverview")
    }
}

private struct RelatedRecords: View {
    let title: String
    let items: [Mark]
    let onSelect: (Mark) -> Void
    @State private var showAll = false

    var body: some View {
        DisclosureGroup("\(title) · \(items.count) 条") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(showAll ? items : Array(items.prefix(4))) { row in
                    Button { onSelect(row) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName).font(.callout).lineLimit(2)
                            Text("\(clockText(row.start)) · \(row.reviewStatus.title)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("relatedRecord-\(row.id)")
                }
                if items.count > 4 {
                    Button(showAll ? "收起" : "显示全部 \(items.count) 条") { showAll.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.top, 5)
        }
        .font(.callout)
    }
}
