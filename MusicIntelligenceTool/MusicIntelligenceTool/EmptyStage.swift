import SwiftUI

/// The first screen: open a file, try the study piece, or pick up a recent record from the shelf.
struct EmptyStage: View {
    let studio: Studio
    let onStudy: () -> Void
    @State private var shelf: [ShelfEntry] = []

    struct ShelfEntry: Identifiable {
        let recent: RecentTrack
        let record: SongRecord
        var id: String { recent.trackID }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    HStack(spacing: 40) {
                        VinylOutline().frame(width: 180, height: 180)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("看清一首歌的结构，逐段试听与校对").font(.largeTitle.weight(.semibold))
                            Text("整理段落和歌词，给片段加注释，再导出记录或分享给 AI 助手。")
                                .font(.body).foregroundStyle(.secondary)
                            HStack(spacing: 14) {
                                Button("打开音频…", action: studio.chooseFile)
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                                Button("用示例体验", action: onStudy)
                                    .controlSize(.large)
                                    .accessibilityIdentifier("openStudy")
                                    .help("用内置练习曲试听一个段落并添加注释")
                            }
                            .padding(.top, 4)
                            Text("可拖入 WAV、MP3、FLAC 或 M4A。示例无需配置分析环境。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !shelf.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("最近打开").font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 24, alignment: .top)],
                                      alignment: .leading, spacing: 24) {
                                ForEach(shelf) { entry in shelfItem(entry) }
                            }
                        }
                    }
                }
                .padding(40)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .task(id: studio.recents.map(\.trackID)) {
            let root = studio.root
            let recents = studio.recents
            let loaded = await Task.detached(priority: .utility) {
                recents.compactMap { recent in
                    Studio.savedRecord(in: root, trackID: recent.trackID).map { ShelfEntry(recent: recent, record: $0) }
                }
            }.value
            if !Task.isCancelled { shelf = loaded }
        }
    }

    private func shelfItem(_ entry: ShelfEntry) -> some View {
        Button { studio.openRecent(entry.recent) } label: {
            VStack(alignment: .leading, spacing: 6) {
                RecordPortrait(record: entry.record, size: 96)
                Text(entry.recent.title).font(Typeface.songti(13, bold: true)).lineLimit(1)
                Text(progress(entry.record)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.recent.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.recent.title)
        .accessibilityValue(progress(entry.record))
    }

    private func progress(_ record: SongRecord) -> String {
        let sections = record.sections
        let confirmed = sections.filter { $0.reviewStatus == .confirmed }.count
        if record.status.isEmpty && confirmed == 0 && sections.count <= 1 { return "尚未分析" }
        return "段落 \(confirmed)/\(sections.count) 已确认"
    }
}
