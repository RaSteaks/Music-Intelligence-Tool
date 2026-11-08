import SwiftUI

/// The first screen: open a file, try the study piece, or pick up a recent record from the shelf.
struct EmptyStage: View {
    let studio: Studio
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
                            Text("音乐分析工作台").font(.largeTitle.weight(.semibold))
                            Text("将音频文件拖入工作区，或点击下方按钮打开。").foregroundStyle(.secondary)
                            Text("支持 WAV、MP3、FLAC 和 M4A").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 14) {
                                Button("打开音频…", action: studio.chooseFile)
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                                Button("试听内置练习曲", action: studio.openStudy)
                                    .controlSize(.large)
                                    .accessibilityIdentifier("openStudy")
                            }
                            .padding(.top, 4)
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
        let confirmed = sections.filter { $0.provenance == .confirmed }.count
        if record.status.isEmpty && confirmed == 0 && sections.count <= 1 { return "尚未分析" }
        return "段落 \(confirmed)/\(sections.count) 已校"
    }
}
