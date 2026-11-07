import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    @Bindable var studio: Studio
    @Binding var page: AppPage
    @State private var pan = 0.0
    @State private var tab = "section"
    @State private var inspector = true
    @State private var showStatus = false
    @State private var showCloudAnalysis = false
    @State private var copyReceipt: UUID?
    @State private var isDropTargeted = false
    @AppStorage(CueEdge.entry.preference) private var inShortcut = CueEdge.entry.defaultKey
    @AppStorage(CueEdge.exit.preference) private var outShortcut = CueEdge.exit.defaultKey
    private let timer = Timer.publish(every: 1/15, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Leaving the workspace removes the waveform, so its I/O key monitor stops while settings are shown.
            if page == .settings {
                SettingsPage(studio: studio)
            } else if let song = studio.song {
                HSplitView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("音乐工作台").font(.caption).foregroundStyle(.secondary)
                                Text(URL(fileURLWithPath: song.path).deletingPathExtension().lastPathComponent)
                                    .font(.title2.bold()).lineLimit(1)
                            }
                            Spacer()
                            Text(song.bpm.map { String(format:"%.1f BPM", $0) } ?? "BPM 待测")
                            Text(song.key ?? "调性待测")
                        }.font(.caption.monospacedDigit())
                        HStack {
                            Button { studio.togglePlayback() } label: { Image(systemName: studio.playing ? "pause.fill" : "play.fill") }
                                .keyboardShortcut(.space, modifiers: []).accessibilityLabel("播放或暂停")
                            Text(clockText(studio.cursor)).font(.system(.title3, design: .monospaced))
                                .accessibilityIdentifier("playheadTime")
                            Text("/ " + clockText(song.duration)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("循环", isOn: $studio.loop).toggleStyle(.button)
                            Picker("音轨", selection: Binding(get: { studio.stem }, set: studio.chooseStem)) {
                                ForEach(["原曲"] + song.stems.keys.sorted(), id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        HStack {
                            Menu("显示轨道") {
                                ForEach(Self.lanes, id: \.0) { kind, title in
                                    Toggle(title, isOn: Binding(get: { studio.visibleKinds.contains(kind) }, set: {
                                        if $0 { studio.visibleKinds.insert(kind) } else { studio.visibleKinds.remove(kind) }
                                    }))
                                }
                            }.fixedSize()
                            Toggle("吸附拍点", isOn: $studio.snap)
                            Spacer()
                            Image(systemName: "magnifyingglass")
                            Slider(value: $studio.zoom, in: 1...24).frame(width: 88).accessibilityLabel("时间轴缩放")
                        }.controlSize(.small)
                        let span = song.duration/studio.zoom
                        let offset = pan * (song.duration-span)
                        let window = offset...(offset+span)
                        WaveformView(record: song, peaks: studio.peaks, visible: studio.visibleKinds, selected: studio.selected,
                                     inPoint: studio.inPoint, outPoint: studio.outPoint, cursor: studio.cursor, window: window, snap: studio.snap,
                                     inShortcut: inShortcut, outShortcut: outShortcut, onShortcut: markAtPlayhead,
                                     onMovePoint: studio.setPoint, onSeek: studio.seek, onPick: studio.select,
                                     onRange: { studio.selection=$0; studio.seek($0.lowerBound) }, onResize: resize)
                            .frame(minHeight: 210, maxHeight: 350)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("waveform")
                            .help("在顶部时间尺点击或拖动可定位播放头；在波形上拖动可设置出入点。")
                        if studio.zoom > 1 {
                            TimelineNavigator(pan: $pan, window: window, duration: song.duration, peaks: studio.peaks)
                                .zIndex(1)
                        }
                        HStack {
                            Button("分段", systemImage: "scissors") { studio.add("section") }
                            Button("加注释", systemImage: "text.badge.plus") { studio.add("note"); tab="note" }
                            Button("加歌词") { studio.add("lyric"); tab="lyric" }
                            Spacer()
                            Menu {
                                Button("标记入点（" + inShortcut.uppercased() + "）") { markAtPlayhead(.entry) }
                                Button("标记出点（" + outShortcut.uppercased() + "）") { markAtPlayhead(.exit) }
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
                        Picker("标注列表", selection: $tab) {
                            Text("段落").tag("section"); Text("歌词").tag("lyric"); Text("注释").tag("note")
                            Text("情绪").tag("emotion"); Text("和弦").tag("chord")
                            Text("解读").tag("insight"); Text("响度").tag("loudness")
                            Text("事件").tag("event")
                            Text("节奏与律动").tag("rhythm")
                            Text("重复关系").tag("repetition")
                            Text("旋律与音域").tag("melody")
                            Text("模型对照").tag("models")
                        }.pickerStyle(.menu).fixedSize()
                        let items = song.marks.filter { row in
                            row.kind == tab || (tab == "chord" && ["key", "key_region", "modulation"].contains(row.kind)) ||
                            (tab == "rhythm" && ["rhythm_summary", "tempo"].contains(row.kind)) ||
                            (tab == "melody" && ["melody_summary", "melody_note", "melody_phrase", "melody_motif"].contains(row.kind)) ||
                            (tab == "event" && row.kind == "insight" && row.fields["category"]?.value == "event")
                        }.sorted { $0.start < $1.start }
                        if tab == "models" {
                            ModelComparisonPanel(studio: studio, song: song)
                        } else if items.isEmpty {
                            Text("当前轨道暂无记录").foregroundStyle(.secondary).padding(.vertical,8)
                            Spacer()
                        } else {
                            List(items, selection: Binding(get: { studio.selected }, set: { id in
                                if let item = items.first(where: { $0.id == id }) { studio.select(item) }
                            })) { item in
                                HStack {
                                    Text(clockText(item.start) + " — " + clockText(item.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(item.label.isEmpty ? "待填写" : item.label).lineLimit(1)
                                    Spacer()
                                    if item.reviewed { Image(systemName:"checkmark.circle").foregroundStyle(.teal) }
                                }
                                .contentShape(Rectangle())
                                .contextMenu {
                                    if item.kind == "section" {
                                        Button("删除分段", role: .destructive) { studio.deleteSection(item.id) }
                                            .disabled(items.count < 2)
                                    }
                                }
                                .tag(item.id)
                            }
                            .listStyle(.inset)
                            .onDeleteCommand(perform: tab == "section" && items.count > 1 && studio.row?.kind == "section" ? {
                                if let id = studio.selected { studio.deleteSection(id) }
                            } : nil)
                        }
                    }.padding(20).frame(minWidth: 480,maxWidth: .infinity)
                    if inspector {
                        ScrollView {
                            VStack(alignment:.leading, spacing:16) {
                                Label("校对面板",systemImage:"slider.horizontal.3").font(.headline)
                                if let row = studio.row {
                                    ReviewPanel(studio: studio, row: row, onCopyForAgent: copyForAgent).id(row.id)
                                } else { Text("选择一个段落或标注开始校对。").foregroundStyle(.secondary) }
                            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                        }.frame(minWidth:220,idealWidth:270,maxWidth:340)
                    }
                }
                Divider()
                HStack {
                    if let version = Self.appVersion {
                        Text("版本 \(version)").monospacedDigit()
                    }
                    if copyReceipt != nil {
                        Label("已复制，可粘贴给 agent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else if let status = studio.agentSendStatus {
                        Text(status).lineLimit(1).help(status)
                            .accessibilityIdentifier("agentSendStatus")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let job = studio.activeJob { ProgressView().controlSize(.small); Text(job.title); Button("取消",action:studio.cancel) }
                    if let progress = studio.cloudProgress {
                        ProgressView().controlSize(.small)
                        Text(progress).lineLimit(1)
                        Button("取消云端", action: studio.cancelCloud)
                    }
                    Button("分析状态与 MCP") { showStatus.toggle() }.popover(isPresented:$showStatus) { statusPanel }
                }.font(.caption).padding(.horizontal,16).padding(.vertical,7)
            } else {
                VStack(spacing: 18) {
                    Image(systemName:"waveform.path").font(.system(size:52,weight:.light)).foregroundStyle(.teal)
                    Text("音乐分析工作台").font(.largeTitle.weight(.semibold))
                    Text("将音频文件拖入工作区，或点击下方按钮打开。").foregroundStyle(.secondary)
                    Button("打开音频…",action:studio.chooseFile).buttonStyle(.borderedProminent).controlSize(.large)
                    Button("试听内置练习曲",action:studio.openStudy).accessibilityIdentifier("openStudy")
                    Text("WAV  /  MP3  /  FLAC  /  M4A").font(.caption.monospaced()).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("页面", selection: $page) {
                    Text("工作区").tag(AppPage.workspace)
                    Text("设置").tag(AppPage.settings)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("pageSwitcher")
            }
            ToolbarItemGroup {
                Button("打开音频",systemImage:"folder") { page = .workspace; studio.chooseFile() }
                    .keyboardShortcut("o").accessibilityIdentifier("openAudio")
                if page == .workspace, studio.song != nil {
                    Menu {
                        Button("分析整首歌曲") { studio.run(Studio.defaultJobs) }
                        Divider()
                        ForEach(AnalysisJob.allCases) { job in
                            Button(job.title) { studio.run([job],range:studio.selection ?? studio.row.map { $0.start...$0.end }) }
                        }
                    } label: { Label("分析",systemImage:"waveform.badge.magnifyingglass") }
                    .disabled(studio.activeJob != nil || studio.modelEnvironment.downloading)
                    Button("外部模型分析", systemImage: "sparkles") { showCloudAnalysis = true }
                        .disabled(studio.cloudRunning).accessibilityIdentifier("openCloudAnalysis")
                    Button("导出 JSON",systemImage:"square.and.arrow.up",action:studio.exportJSON)
                    Button("撤销",systemImage:"arrow.uturn.backward",action:studio.undo).disabled(!studio.canUndo)
                        .keyboardShortcut("z")
                    Button("检查面板",systemImage:"sidebar.right") { inspector.toggle() }
                }
            }
        }
        .frame(minWidth:830,minHeight:580)
        .sheet(isPresented: $showCloudAnalysis) { CloudAnalysisSheet(studio: studio) }
        .onChange(of: studio.selected) {
            if let row = studio.row, row.kind == "insight", tab != "event" || row.fields["category"]?.value != "event" { tab = "insight" }
        }
        .onChange(of: studio.completedComparisonID) { if studio.completedComparisonID != nil { tab = "models" } }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard page == .workspace else { return false }
            return studio.openDroppedAudio(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted && page == .workspace
        }
        .overlay {
            if isDropTargeted && page == .workspace {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.teal.opacity(0.08))
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.teal, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    Label("松开以打开音频", systemImage: "arrow.down.doc")
                        .font(.headline).padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .onReceive(timer) { _ in studio.tick() }
        .onChange(of:studio.song?.trackID) { pan=0; tab="section"; copyReceipt=nil }
        .task(id: copyReceipt) {
            guard copyReceipt != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { copyReceipt = nil }
        }
        .alert("音乐工作台",isPresented:Binding(get:{ studio.notice != nil },set:{ if !$0 { studio.notice=nil } })) {
            Button("确定") { studio.notice=nil }
        } message: { Text(studio.notice ?? "") }
    }
    private func copyForAgent() {
        guard let song = studio.song else { return }
        do {
            let message = try song.agentMessage(mcpEndpoint: studio.mcpEndpoint)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(message, forType: .string) {
                copyReceipt = UUID()
            } else {
                copyReceipt = nil
                studio.notice = "写入剪贴板失败，请重试。"
            }
        } catch {
            copyReceipt = nil
            studio.notice = error.localizedDescription
        }
    }
    private var pointReadout: String {
        if studio.inPoint == nil && studio.outPoint == nil { return "出入点" }
        return "入 " + (studio.inPoint.map(clockText) ?? "—") + "   出 " + (studio.outPoint.map(clockText) ?? "—")
    }
    private func markAtPlayhead(_ edge: CueEdge) {
        studio.markPoint(edge)
    }
    static let lanes = [("section","段落"),("beat","拍点"),("downbeat","小节第一拍"),("onset","起音"),
                        ("acoustic","声学能量"),("emotion","情绪走势"),("lyric","歌词"),("word","字词"),
                        ("chord","和弦"),("note","注释"),("event","声部活动与停顿"),("insight","选中解读范围"),
                        ("tempo","局部速度"),("repetition","重复片段"),("pitch","旋律音高")]
    private var statusPanel: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:10) {
            Text("分析状态").font(.headline)
            ForEach(AnalysisJob.allCases) { j in
                HStack { Text(j.title); Spacer(); Text(studio.song?.status[j.rawValue] ?? "未运行").foregroundStyle(.secondary) }
                if let warnings = studio.song?.warnings?[j.rawValue], !warnings.isEmpty {
                    Text(warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                }
            }
            if let runs = studio.song?.cloudRuns, !runs.isEmpty {
                Divider()
                Text("外部分析记录").font(.headline)
                VStack(alignment: .leading, spacing: 10) {
                        ForEach(runs.reversed()) { run in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.task.title + " · " + run.status)
                                Text(run.provider + " / " + (run.actualModel ?? run.model)).font(.caption)
                                Text(clockText(run.range.start) + " — " + clockText(run.range.end)).font(.caption.monospacedDigit())
                                if let message = run.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                                if let usage = run.usage, !usage.isEmpty {
                                    Text(usage.keys.sorted().map { "\($0): \(usage[$0] ?? 0)" }.joined(separator: "，")).font(.caption)
                                }
                            }.textSelection(.enabled)
                        }
                }
            }
            if let batches = studio.song?.cloudBatches, !batches.isEmpty {
                Divider()
                ForEach(batches.suffix(3).reversed()) { batch in
                    Text("\(batch.mode == "models" ? "模型对照" : "整曲批次") · \(batch.status) · 已提交 \(batch.submittedRequests)/\(batch.maximumRequests) 次")
                        .font(.caption)
                    if let message = batch.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            Text("MCP · " + studio.serviceStatus).font(.caption.monospaced()).textSelection(.enabled)
        }.padding()
        }.frame(width: 460, height: 520)
    }
    private func resize(id: String, start: Bool, time: Double) {
        studio.edit { doc in
            guard let i = doc.marks.firstIndex(where: { $0.id == id }) else { return }
            let row = doc.marks[i]
            if row.kind == "section" { doc.moveBoundary(left:id,to:time) }
            else if row.kind == "lyric" {
                if start && time < row.end { doc.marks[i].start=time; doc.marks[i].startConfirmed=true }
                if !start && time > row.start { doc.marks[i].end=time; doc.marks[i].endConfirmed=true }
                doc.invalidateWords(from:min(time,row.start),to:max(time,row.end))
            }
        }
    }
}

private struct ReviewPanel: View {
    let studio: Studio
    let row: Mark
    let onCopyForAgent: () -> Void
    @State private var field = "label"
    @State private var draft = ""
    @State private var hint = ""
    @State private var startText = ""
    @State private var endText = ""
    private var saved: ReviewedText { row.fields[field] ?? ReviewedText() }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(clockText(row.start) + " — " + clockText(row.end)).font(.caption.monospaced())
            if ["section", "lyric", "note", "insight", "event", "melody_note", "repetition"].contains(row.kind) {
                HStack {
                    TextField("起点（秒）", text: $startText).accessibilityIdentifier("rangeStart")
                    TextField("终点（秒）", text: $endText).accessibilityIdentifier("rangeEnd")
                    Button("应用") { applyTimes() }.accessibilityIdentifier("applyRange")
                }
            }
            Button("循环试听选段",systemImage:"repeat") {
                studio.selection = row.start...row.end; studio.seek(row.start); studio.loop=true
                if !studio.playing { studio.togglePlayback() }
            }
            if ["repetition", "melody_motif"].contains(row.kind), let start = row.metrics["reference_start_s"], let end = row.metrics["reference_end_s"] {
                Button("循环试听参考片段") {
                    studio.selection = start...end; studio.seek(start); studio.loop = true
                    if !studio.playing { studio.togglePlayback() }
                }
            }
            Divider()
            if row.analysisStale == true {
                Text("参考输入或检测边界已变化，此候选待核对；人工确认值仍保留。").font(.caption).foregroundStyle(.orange)
            }
            if row.kind == "event", let source = row.fields["event_type"]?.value,
               studio.song?.stems[source] != nil {
                Button("试听对应分轨") {
                    studio.chooseStem(source); studio.selection = row.start...row.end; studio.seek(row.start)
                    studio.loop = true
                    if !studio.playing { studio.togglePlayback() }
                }
            }
            if let source = row.fields["audio_source"]?.value {
                Button("试听分析音轨") {
                    studio.chooseStem(source == "original" ? "原曲" : source)
                    studio.selection = row.start...row.end; studio.seek(row.start); studio.loop = true
                    if !studio.playing { studio.togglePlayback() }
                }
            }
            Picker("字段",selection:$field) {
                Text("名称 / 唱词").tag("label"); Text("听感").tag("mood"); Text("音乐内容").tag("content")
                if row.fields["degree"] != nil { Text("和声级数候选").tag("degree") }
                if row.fields["meter"] != nil { Text("拍号线索").tag("meter") }
                if row.fields["groove"] != nil { Text("律动线索").tag("groove") }
            }
            if let original = saved.suggested {
                Text("模型建议 · " + original).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if saved.rejected == true { Text("此字段的建议已拒绝").font(.caption).foregroundStyle(.secondary) }
                if let origin = saved.origin {
                    Text(origin.stale ? "基于旧输入，待更新；确认前请重新试听。" : "模型候选，待人工核对。")
                        .font(.caption).foregroundStyle(origin.stale ? .orange : .secondary)
                    Text(origin.provider + " / " + origin.model).font(.caption).textSelection(.enabled)
                    if !origin.uncertainty.isEmpty { Text("不确定处：" + origin.uncertainty).font(.caption) }
                    let context = studio.song?.cloudRuns?.first(where: { $0.id == origin.runID })?.context
                    ForEach(Array(Set(origin.evidenceIDs)).sorted(), id: \.self) { id in
                        if let reference = context?.audioReferences?.first(where: { $0.id == id }) {
                            Text("音频依据 · \(reference.source.title) · \(clockText(reference.range.start)) — \(clockText(reference.range.end))")
                                .font(.caption)
                        } else if id == "audio" {
                            Text("依据：本次发送的选区音频").font(.caption)
                        } else {
                            if let evidence = context?.items.first(where: { $0.id == id }) {
                                let label = evidence.fields["label"]?.confirmed ?? evidence.fields["label"]?.suggested ?? evidence.kind
                                Text("输入快照：" + label + "（" + clockText(evidence.start) + "）").font(.caption).textSelection(.enabled)
                                if !evidence.metrics.isEmpty {
                                    DisclosureGroup("输入统计") {
                                        ForEach(evidence.metrics.keys.sorted(), id: \.self) { key in
                                            Text(metricText(key, value: evidence.metrics[key] ?? 0)).font(.caption.monospacedDigit())
                                        }
                                    }
                                }
                            }
                            if let current = studio.song?.marks.first(where: { $0.id == id }) {
                                Button("定位当前条目") { studio.select(current) }.font(.caption)
                            } else { Text("当前条目已移除").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            TextField("校对后的内容", text:$draft, axis:.vertical).lineLimit(2...5)
            Button("确认此字段",systemImage:"checkmark") { update(confirm:true) }.buttonStyle(.borderedProminent)
            if saved.suggested != nil {
                Button(saved.rejected == true ? "恢复此字段建议" : "拒绝此字段建议") {
                    studio.edit { doc in
                        if let index = doc.marks.firstIndex(where: { $0.id == row.id }) {
                            doc.marks[index].fields[field, default: ReviewedText()].rejected = saved.rejected != true
                        }
                    }
                }.font(.caption)
            }
            TextField("给分析的提示",text:$hint,axis:.vertical).lineLimit(2...4)
            HStack {
                Button("保存提示") { update(confirm:false) }
                Button("发送给 agent", systemImage: "paperplane") { Task { await studio.sendToAgent() } }
                    .labelStyle(.iconOnly)
                    .disabled(studio.sendingToAgent)
                    .accessibilityIdentifier("sendToAgent")
                    .help("将当前歌曲的完整分析记录发送给 Claude Code")
                Button("复制交接文本", systemImage: "document.on.clipboard", action: onCopyForAgent)
                    .labelStyle(.iconOnly)
                    .help("复制完整分析记录和 MCP 查询指令，可手动粘贴给 agent")
            }
            if let song = studio.song, row.kind == "section" {
                let summary = song.summary(for:row)
                if !summary.isEmpty { Divider(); Text(summary).font(.callout).textSelection(.enabled) }
            }
            if !row.metrics.isEmpty {
                ForEach(row.metrics.keys.sorted(),id:\.self) { key in
                    Text(metricText(key, value: row.metrics[key] ?? 0)).font(.caption.monospacedDigit())
                }
                if row.metrics["template_similarity"] != nil || row.metrics["profile_correlation"] != nil {
                    Text("匹配分数和候选差距用于核对，不是识别准确率。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            if row.kind == "section" || row.kind == "lyric" {
                Button("在播放头拆分") { let t=studio.position; studio.edit { $0.split(row.id,at:t) } }
                Button("合并下一段") { studio.edit { $0.mergeNext(row.id) } }
            }
            if row.kind == "section" {
                Button("删除分段", role: .destructive) { studio.deleteSection(row.id) }
                    .disabled((studio.song?.sections.count ?? 0) < 2)
                    .help("时间并入前一段；删除首段时并入后一段。至少保留一段。")
            }
            if row.kind == "lyric" {
                Menu("演唱状态") {
                    ForEach(["已辨认","纯器乐","有演唱但听不清"],id:\.self) { state in
                        Button(state) {
                            studio.edit { doc in
                                if let i=doc.marks.firstIndex(where: { $0.id == row.id }) {
                                    doc.marks[i].fields["vocal_state"] = ReviewedText(confirmed:state)
                                }
                            }
                        }
                    }
                }
                if let value=row.fields["vocal_state"]?.value { Text(value).font(.caption) }
            }
            if row.kind == "note" { Button("删除注释") { studio.edit { $0.marks.removeAll { $0.id == row.id } } } }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear(perform:load)
        .onChange(of:field,load)
        .onChange(of:row.fields,load)
        .onChange(of:row.start,load)
        .onChange(of:row.end,load)
    }
    private func load() {
        draft = saved.confirmed ?? saved.suggested ?? ""
        hint = saved.hint ?? ""
        startText = String(format: "%.3f", row.start)
        endText = String(format: "%.3f", row.end)
    }
    private func metricText(_ key: String, value: Double) -> String {
        if key.hasPrefix("mean_") { return "区间均值 · " + metricText(String(key.dropFirst(5)), value: value) }
        let descriptions = [
            "integrated_lufs": ("综合响度", "LUFS"), "short_lufs": ("短时响度", "LUFS"),
            "loudness_range_lu": ("响度范围", "LU"), "true_peak_dbtp": ("真峰值", "dBTP"),
            "sample_peak_dbfs": ("采样峰值", "dBFS"), "rms_dbfs": ("RMS", "dBFS"),
            "crest_db": ("峰均比", "dB"), "stereo_correlation": ("声道相关系数", ""),
            "channels": ("声道数", ""), "sample_rate_hz": ("原始采样率", "Hz"),
            "measured_duration_s": ("测量时长", "秒"), "template_similarity": ("和弦模板匹配", ""),
            "template_margin": ("和弦候选差距", ""), "profile_correlation": ("调性轮廓相关", ""),
            "profile_margin": ("调性候选差距", ""), "centroid_hz": ("频谱重心", "Hz"),
            "onsets_per_s": ("起音密度", "次/秒"), "valence": ("效价", ""), "arousal": ("唤醒度", ""),
            "threshold_dbfs": ("活动门限", "dBFS"), "resolution_s": ("检测时间分辨率", "秒"), "bridged_gap_s": ("合并间隙上限", "秒"),
            "tempo_bpm": ("参考速度", "BPM"), "half_tempo_bpm": ("半速候选", "BPM"), "double_tempo_bpm": ("倍速候选", "BPM"),
            "beat_interval_mad": ("拍间相对变异", ""), "beats_per_bar": ("每小节检测拍数", ""), "meter_support": ("拍号线索支持度", ""),
            "swing_ratio": ("长短拍比例", ""), "offbeat_onset_fraction": ("离拍起音比例", ""),
            "frequency_hz": ("音高频率", "Hz"), "midi_pitch": ("连续音高", "MIDI"), "midi_note": ("音符候选", "MIDI"),
            "pitch_low_midi": ("音域下界", "MIDI"), "pitch_high_midi": ("音域上界", "MIDI"), "pitch_span_semitones": ("检测跨度", "半音"),
            "pitched_fraction": ("检测到音高的时长占比", ""), "pitch_salience": ("旋律显著度（非准确率）", ""), "vibrato_hz": ("音高调制线索", "Hz"),
            "similarity": ("片段相似度（非准确率）", ""), "transpose_semitones": ("移调候选", "半音"), "duration_ratio": ("片段时长比", ""),
            "reference_start_s": ("参考片段起点", "秒"), "reference_end_s": ("参考片段终点", "秒")
        ]
        if key.hasPrefix("coverage_") {
            let metric = String(key.dropFirst(9))
            return (descriptions[metric]?.0 ?? metric) + String(format: " 有效覆盖 %.1f%%", value * 100)
        }
        for suffix in ["_activity_fraction", "_coverage"] where key.hasSuffix(suffix) {
            let source = String(key.dropLast(suffix.count))
            let title = CloudAudioSource(rawValue: source)?.title ?? (source == "silence" ? "近静音" : source)
            return title + (suffix == "_coverage" ? " 检测覆盖" : " 活动占比") + String(format: " %.1f%%", value * 100)
        }
        if key == "full_scale_fraction" { return String(format: "满幅采样占比  %.4f%%", value * 100) }
        let description = descriptions[key] ?? (key, "")
        return description.0 + "  " + String(format: "%.2f", value) + " " + description.1
    }
    private func applyTimes() {
        guard let a = Double(startText), let b = Double(endText), let song = studio.song,
              a >= 0, b <= song.duration, row.kind == "note" ? a <= b : a < b else {
            studio.notice = "请输入歌曲时长内的有效起止时间。"; return
        }
        studio.edit { doc in
            guard let i = doc.marks.firstIndex(where: { $0.id == row.id }) else { return }
            if row.kind == "section" {
                if let previous = doc.sections.last(where: { $0.end == row.start }), a != row.start {
                    doc.moveBoundary(left: previous.id, to: a)
                }
                if b != row.end { doc.moveBoundary(left: row.id, to: b) }
            } else {
                doc.marks[i].start = a; doc.marks[i].end = b
                doc.marks[i].startConfirmed = true; doc.marks[i].endConfirmed = true
                if row.kind == "lyric" { doc.invalidateWords(from: min(a,row.start), to: max(b,row.end)) }
            }
        }
    }
    private func update(confirm: Bool) {
        studio.edit { doc in
            guard let i=doc.marks.firstIndex(where:{ $0.id == row.id }) else { return }
            if confirm {
                doc.marks[i].fields[field,default:ReviewedText()].confirmed=draft
                if row.kind == "lyric" && field == "label" { doc.invalidateWords(from:row.start,to:row.end) }
            } else { doc.marks[i].fields[field,default:ReviewedText()].hint=hint.isEmpty ? nil : hint }
        }
    }
}
