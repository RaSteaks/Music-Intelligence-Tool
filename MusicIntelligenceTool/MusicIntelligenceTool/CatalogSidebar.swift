import SwiftUI

struct CatalogCategory: Identifiable {
    enum Group: String, CaseIterable, Identifiable {
        case structure = "结构与标注"
        case sound = "听感与声音"
        case music = "音乐细节"
        case interpretation = "AI 解读"
        var id: Self { self }
    }

    let id: String
    let title: String
    let icon: String
    let group: Group
    let job: AnalysisJob?
    let detail: String

    static let all: [CatalogCategory] = [
        .init(id: "section", title: "段落", icon: "rectangle.split.3x1", group: .structure, job: .structure, detail: "定位歌曲结构和段落变化"),
        .init(id: "lyric", title: "歌词", icon: "quote.bubble", group: .structure, job: .lyrics, detail: "逐句试听、填写与校对歌词"),
        .init(id: "note", title: "注释", icon: "bookmark", group: .structure, job: nil, detail: "记录一个时刻或片段的听感"),
        .init(id: "emotion", title: "情绪", icon: "theatermasks", group: .sound, job: .emotion, detail: "查看情绪候选和随时间的变化"),
        .init(id: "event", title: "事件", icon: "waveform.path.ecg", group: .sound, job: .events, detail: "定位人声、鼓与贝斯的活动和停顿"),
        .init(id: "loudness", title: "响度", icon: "speaker.wave.2", group: .sound, job: .acoustics, detail: "查看所测区间的响度与动态"),
        .init(id: "chord", title: "和弦", icon: "pianokeys", group: .music, job: .harmony, detail: "核对调性、转调和和弦候选"),
        .init(id: "rhythm", title: "节奏与律动", icon: "metronome", group: .music, job: .rhythm, detail: "查看速度变化、拍号和律动线索"),
        .init(id: "repetition", title: "重复关系", icon: "repeat", group: .music, job: .repetition, detail: "找到相似片段并对照试听"),
        .init(id: "melody", title: "旋律与音域", icon: "music.note", group: .music, job: .melody, detail: "查看音符、乐句和检测到的音域"),
        .init(id: "insight", title: "解读", icon: "sparkles", group: .interpretation, job: nil, detail: "查看外部模型的结论与依据"),
        .init(id: "models", title: "模型对照", icon: "rectangle.split.2x1", group: .interpretation, job: nil, detail: "比较两个模型对同一输入的结论")
    ]

    static func category(_ id: String) -> CatalogCategory? { all.first { $0.id == id } }
    static func title(_ id: String) -> String { category(id)?.title ?? id }

    static func items(_ tab: String, in song: SongRecord) -> [Mark] {
        // Comparison findings are the same records shown in the insight list, not copies.
        if tab == "models" {
            let runs = Set((song.cloudBatches ?? []).filter { $0.mode == "models" }.flatMap(\.runIDs))
            return song.marks.filter { $0.fields["label"]?.origin.map { runs.contains($0.runID) } == true }
                .sorted { $0.start < $1.start }
        }
        return song.marks.filter { row in
            row.kind == tab || (tab == "chord" && ["key", "key_region", "modulation"].contains(row.kind)) ||
            (tab == "rhythm" && ["rhythm_summary", "tempo"].contains(row.kind)) ||
            (tab == "melody" && ["melody_summary", "melody_note", "melody_phrase", "melody_motif"].contains(row.kind)) ||
            (tab == "event" && row.kind == "insight" && row.fields["category"]?.value == "event")
        }.sorted { $0.start < $1.start }
    }
}

enum CatalogFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case pending = "待核对"
    case confirmed = "已确认"
    case rejected = "已拒绝"
    var id: Self { self }

    func includes(_ row: Mark) -> Bool {
        switch self {
        case .all: true
        case .pending: row.reviewStatus.needsReview
        case .confirmed: row.reviewStatus == .confirmed
        case .rejected: row.reviewStatus == .rejected
        }
    }
}

extension Mark {
    var displayName: String {
        if kind == "lyric", label.isEmpty, let state = fields["vocal_state"]?.confirmed, state != "已辨认" { return state }
        if kind == "note", label.isEmpty, let content = fields["content"]?.value, !content.isEmpty { return content }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "待填写" }
        return label == kind && fields["label"]?.value == nil ? ReviewCard.kindTitles[kind] ?? label : label
    }
}

struct CatalogSidebar: View {
    let studio: Studio
    let song: SongRecord
    @Binding var tab: String
    @Binding var filter: CatalogFilter
    let onCategory: (String) -> Void
    let onSelect: (Mark) -> Void
    let onAnalyze: (AnalysisJob) -> Void
    let onCloud: (Bool) -> Void
    let onAdd: (String) -> Void
    @State private var expanded: Set<CatalogCategory.Group> = [.structure]

    var body: some View {
        let items = CatalogCategory.items(tab, in: song)
        let shown = items.filter(filter.includes)
        VStack(spacing: 0) {
            songHeader
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    directory.frame(height: min(220, geometry.size.height * 0.39))
                    Divider()
                    resultsHeader(items: items, selected: shown.first { $0.id == studio.selected })
                    recordList(items: items, shown: shown)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private var songHeader: some View {
        HStack(spacing: 10) {
            RecordPortrait(record: song, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: song.path).deletingPathExtension().lastPathComponent)
                    .font(Typeface.songti(15, bold: true)).lineLimit(2)
                Text([song.key, song.bpm.map { String(format: "%.1f BPM", $0) }, durationText(song.duration)]
                    .compactMap { $0 }.joined(separator: "  "))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var directory: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(CatalogCategory.Group.allCases) { group in
                    Button {
                        if expanded.contains(group) { expanded.remove(group) } else { expanded.insert(group) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: expanded.contains(group) ? "chevron.down" : "chevron.right")
                                .imageScale(.small).accessibilityHidden(true)
                            Text(group.rawValue).font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityValue(expanded.contains(group) ? "已展开" : "已折叠")
                    .accessibilityIdentifier("catalogGroup-\(group)")
                    if expanded.contains(group) {
                        ForEach(CatalogCategory.all.filter { $0.group == group }) { category in
                            categoryButton(category).padding(.leading, 12).id(category.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("catalogNavigation")
            .task(id: tab) {
                guard let category = CatalogCategory.category(tab) else { return }
                guard expanded.insert(category.group).inserted else { return }
                // Give the section a layout pass to reveal the destination after expanding it.
                await Task.yield()
                if !Task.isCancelled { proxy.scrollTo(tab, anchor: .center) }
            }
        }
    }

    private func categoryButton(_ category: CatalogCategory) -> some View {
        let items = CatalogCategory.items(category.id, in: song)
        return Button { onCategory(category.id) } label: {
            HStack {
                Label(category.title, systemImage: category.icon)
                Spacer(minLength: 4)
                if !items.isEmpty {
                    Text(items.count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(tab == category.id ? Tone.sound.color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityAddTraits(tab == category.id ? .isSelected : [])
        .accessibilityValue("共 \(items.count) 条")
        .accessibilityIdentifier("catalogCategory-\(category.id)")
        .help(category.detail)
    }

    private func resultsHeader(items: [Mark], selected: Mark?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(CatalogCategory.title(tab)).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Menu {
                    if let selected { RecordActions(studio: studio, song: song, item: selected, onLocate: onSelect) }
                } label: {
                    Label("更多操作", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(selected == nil)
                .help(selected == nil ? "选中条目后可操作" : "操作选中的条目")
                .accessibilityIdentifier("catalogMoreActions")
            }
            HStack(spacing: 5) {
                Text("已确认 \(items.filter { $0.reviewStatus == .confirmed }.count)/\(items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("catalogProgress")
                Spacer(minLength: 0)
                Picker("筛选条目", selection: $filter) {
                    ForEach(CatalogFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .accessibilityIdentifier("catalogFilter")
            }
        }
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 5)
    }

    @ViewBuilder private func recordList(items: [Mark], shown: [Mark]) -> some View {
        if shown.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text(CatalogCategory.category(tab)?.detail ?? "暂无条目").font(.callout)
                        if let job = CatalogCategory.category(tab)?.job, let state = song.status[job.rawValue] {
                            Text(state).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let job = CatalogCategory.category(tab)?.job {
                            Button(tab == "lyric" ? "识别歌词…" : "开始分析…") { onAnalyze(job) }
                                .disabled(studio.activeJob != nil)
                        }
                        if tab == "note" || tab == "lyric" {
                            Button(tab == "note" ? "添加注释" : "手动添加歌词") { onAdd(tab) }
                                .help("使用选区起止点，或在播放头位置添加")
                        }
                        if tab == "insight" || tab == "models" {
                            Button(tab == "models" ? "创建模型对照…" : "用外部模型解读…") { onCloud(tab == "models") }
                                .disabled(studio.cloudRunning)
                        }
                    } else {
                        Text("没有符合筛选条件的条目").font(.callout)
                        Button("显示全部") { filter = .all }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .accessibilityIdentifier("catalogEmpty")
            }
        } else {
            ScrollViewReader { proxy in
                List(selection: Binding(get: { studio.selected }, set: { id in
                    if let item = shown.first(where: { $0.id == id }) { onSelect(item) }
                })) {
                    ForEach(shown) { item in
                        itemRow(item)
                            .tag(item.id)
                            .id(item.id)
                            .contextMenu { RecordActions(studio: studio, song: song, item: item, onLocate: onSelect) }
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("catalogRecords")
                .onDeleteCommand(perform: shown.contains(where: { $0.id == studio.selected && ($0.kind != "section" || song.sections.count > 1) }) ? {
                    if let id = studio.selected { studio.deleteMark(id) }
                } : nil)
                .onChange(of: studio.selected, initial: true) { _, id in
                    if let id, shown.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func itemRow(_ item: Mark) -> some View {
        let state = item.reviewStatus
        return HStack(spacing: 6) {
            ProvenanceGlyph(state: item.provenance, hint: item.hasHint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .fontWeight(state == .confirmed ? .semibold : .regular)
                    .strikethrough(state == .rejected)
                    .lineLimit(1)
                Text("\(clockText(item.start)) · \(state.title)" + (item.hasHint ? " · 有提示" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("catalogItem-\(item.id)")
    }
}

/// Both menu entry points operate on the record passed in, even if a different row is selected.
private struct RecordActions: View {
    let studio: Studio
    let song: SongRecord
    let item: Mark
    let onLocate: (Mark) -> Void

    var body: some View {
        Button("定位并校对", systemImage: "scope") { onLocate(item) }
        Button("循环试听", systemImage: "repeat") {
            studio.select(item)
            studio.audition(item.timeRange)
        }
        .disabled(item.end <= item.start)
        Divider()
        Button(item.kind == "section" ? "删除分段" : "删除\(ReviewCard.kindTitles[item.kind] ?? "条目")",
               systemImage: "trash", role: .destructive) { studio.deleteMark(item.id) }
            .disabled(item.kind == "section" && song.sections.count < 2)
    }
}

func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
