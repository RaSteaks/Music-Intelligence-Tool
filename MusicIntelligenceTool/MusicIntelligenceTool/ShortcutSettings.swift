import SwiftUI

enum CueEdge: CaseIterable {
    case entry, exit

    var title: String { self == .entry ? "入点" : "出点" }
    var defaultKey: String { self == .entry ? "i" : "o" }
    var preference: String { self == .entry ? "cueInShortcut" : "cueOutShortcut" }
}

struct ShortcutSettings: View {
    @AppStorage(CueEdge.entry.preference) private var entry = CueEdge.entry.defaultKey
    @AppStorage(CueEdge.exit.preference) private var exit = CueEdge.exit.defaultKey
    private let keys = "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)

    var body: some View {
        Form {
            Section {
                picker(.entry, key: $entry, occupied: exit)
                picker(.exit, key: $exit, occupied: entry)
            } header: {
                Text("时间轴快捷键")
            } footer: {
                Text("在播放头处标记。编辑歌词或注释时可正常输入这些字符。")
            }
            Button("恢复默认快捷键") {
                entry = CueEdge.entry.defaultKey
                exit = CueEdge.exit.defaultKey
            }
            .disabled(entry == CueEdge.entry.defaultKey && exit == CueEdge.exit.defaultKey)
        }
        .formStyle(.grouped)
    }

    private func picker(_ edge: CueEdge, key: Binding<String>, occupied: String) -> some View {
        Picker("标记" + edge.title, selection: key) {
            ForEach(keys, id: \.self) { letter in
                Text(letter.uppercased()).tag(letter).disabled(letter == occupied)
            }
        }
    }
}
