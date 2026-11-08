import SwiftUI

/// Categories of the record. Each shows how much of it a person has reviewed.
struct CatalogCategory: Identifiable {
    let id: String
    let title: String
    let icon: String

    static let all: [CatalogCategory] = [
        .init(id: "section", title: "段落", icon: "rectangle.split.3x1"),
        .init(id: "lyric", title: "歌词", icon: "quote.bubble"),
        .init(id: "note", title: "注释", icon: "bookmark"),
        .init(id: "emotion", title: "情绪", icon: "theatermasks"),
        .init(id: "chord", title: "和弦", icon: "pianokeys"),
        .init(id: "insight", title: "解读", icon: "sparkles"),
        .init(id: "loudness", title: "响度", icon: "speaker.wave.2"),
        .init(id: "event", title: "事件", icon: "waveform.path.ecg"),
        .init(id: "rhythm", title: "节奏与律动", icon: "metronome"),
        .init(id: "repetition", title: "重复关系", icon: "repeat"),
        .init(id: "melody", title: "旋律与音域", icon: "music.note"),
        .init(id: "models", title: "模型对照", icon: "rectangle.split.2x1")
    ]
    /// Categories a person can write into stay listed even while empty.
    static let authored: Set<String> = ["section", "lyric", "note"]

    static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? id }

    static func items(_ tab: String, in song: SongRecord) -> [Mark] {
        song.marks.filter { row in
            row.kind == tab || (tab == "chord" && ["key", "key_region", "modulation"].contains(row.kind)) ||
            (tab == "rhythm" && ["rhythm_summary", "tempo"].contains(row.kind)) ||
            (tab == "melody" && ["melody_summary", "melody_note", "melody_phrase", "melody_motif"].contains(row.kind)) ||
            (tab == "event" && row.kind == "insight" && row.fields["category"]?.value == "event")
        }.sorted { $0.start < $1.start }
    }

    static func comparisons(in song: SongRecord) -> Int {
        (song.cloudBatches ?? []).filter { $0.mode == "models" }.count
    }
}

struct CatalogSidebar: View {
    let studio: Studio
    let song: SongRecord
    @Binding var tab: String

    private var title: String { URL(fileURLWithPath: song.path).deletingPathExtension().lastPathComponent }

    var body: some View {
        let items = CatalogCategory.items(tab, in: song)
        List(selection: Binding(get: { studio.selected }, set: { id in
            if let item = items.first(where: { $0.id == id }) { studio.select(item) }
        })) {
            Section {
                HStack(spacing: 10) {
                    RecordPortrait(record: song, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Typeface.songti(15, bold: true)).lineLimit(2)
                        Text(songDetails).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("目录") {
                ForEach(visibleCategories) { category in
                    Button { tab = category.id } label: {
                        HStack {
                            Label(category.title, systemImage: category.icon)
                            Spacer()
                            Text(progress(category.id)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(tab == category.id ? Tone.sound.color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityAddTraits(tab == category.id ? .isSelected : [])
                    .accessibilityValue(progressDescription(category.id))
                }
            }
            Section(CatalogCategory.title(tab)) {
                if tab == "models" {
                    Text("对照结果显示在时间轴下方。").font(.caption).foregroundStyle(.secondary)
                } else if items.isEmpty {
                    Text(CatalogCategory.authored.contains(tab) ? "还没有记录。用走带条上的按钮添加。" : "这一类还没有分析结果。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        itemRow(item)
                            .tag(item.id)
                            .contextMenu {
                                if item.kind == "section" {
                                    Button("删除分段", role: .destructive) { studio.deleteSection(item.id) }
                                        .disabled(items.count < 2)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: tab == "section" && items.count > 1 && studio.row?.kind == "section" ? {
            if let id = studio.selected { studio.deleteSection(id) }
        } : nil)
    }

    private var songDetails: String {
        [song.key, song.bpm.map { String(format: "%.1f BPM", $0) }, durationText(song.duration)]
            .compactMap { $0 }.joined(separator: "  ")
    }

    private var visibleCategories: [CatalogCategory] {
        CatalogCategory.all.filter { category in
            if category.id == "models" { return CatalogCategory.comparisons(in: song) > 0 || tab == "models" }
            return CatalogCategory.authored.contains(category.id) || category.id == tab
                || !CatalogCategory.items(category.id, in: song).isEmpty
        }
    }

    private func progress(_ id: String) -> String {
        if id == "models" { return String(CatalogCategory.comparisons(in: song)) }
        let items = CatalogCategory.items(id, in: song)
        if items.isEmpty { return "—" }
        if id == "note" { return String(items.count) }
        return "\(items.filter(\.reviewed).count)/\(items.count)"
    }
    private func progressDescription(_ id: String) -> String {
        let items = CatalogCategory.items(id, in: song)
        if id == "models" { return "\(CatalogCategory.comparisons(in: song)) 次对照" }
        if items.isEmpty { return "暂无记录" }
        if id == "note" { return "\(items.count) 条" }
        return "共 \(items.count) 条，已校 \(items.filter(\.reviewed).count) 条"
    }

    private func itemRow(_ item: Mark) -> some View {
        let state = item.provenance
        return HStack(spacing: 6) {
            ProvenanceGlyph(state: state, hint: item.hasHint)
            Text(clockText(item.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(item.label.isEmpty ? "待填写" : item.label)
                .fontWeight(state == .confirmed ? .semibold : .regular)
                .foregroundStyle(state == .confirmed ? Color.primary : Tone.pencil.color)
                .strikethrough(state == .rejected)
                .opacity(state == .stale ? 0.6 : 1)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
