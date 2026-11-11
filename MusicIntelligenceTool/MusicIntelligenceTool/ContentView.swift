import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    @Bindable var studio: Studio
    @Binding var page: AppPage
    @State private var pan = 0.0
    @State private var tab = "section"
    @State private var catalogFilter = CatalogFilter.all
    @State private var inspector = true
    @State private var showStatus = false
    @State private var sheet: WorkspaceSheet?
    @State private var dismissedAnalysisResult: UUID?
    /// A short confirmation shown in the toolbar after an action finishes, next to where it was started.
    @State private var receipt: Receipt?
    @State private var studyStep: StudyStep?
    @State private var studyTrackID: String?
    @State private var showManualHint = false
    @State private var isDropTargeted = false
    @AppStorage("rulerBars") private var rulerBars = false
    @AppStorage("reviewAutoAudition") private var autoAudition = false
    @AppStorage(CueEdge.entry.preference) private var inShortcut = CueEdge.entry.defaultKey
    @AppStorage(CueEdge.exit.preference) private var outShortcut = CueEdge.exit.defaultKey

    var body: some View {
        Group {
            // Leaving the workspace removes the waveform, so its I/O key monitor stops while settings are shown.
            if page == .settings {
                SettingsPage(studio: studio)
            } else if let song = studio.song {
                workspace(song)
            } else {
                EmptyStage(studio: studio, onStudy: openStudy)
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .background { PlaybackClock(studio: studio, playing: studio.playing).frame(width: 0, height: 0) }
        .toolbar { toolbar }
        .frame(minWidth: 830, minHeight: 580)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .analysis(let request):
                AnalysisPreparationSheet(studio: studio, request: request)
            case .cloud(let compare):
                CloudAnalysisSheet(studio: studio, compare: compare)
            case .delivery(let song):
                HandoffSheet(studio: studio, song: song, onCopy: { copyForAgent(song) }, onExported: {
                    confirm("已导出 " + $0.lastPathComponent)
                })
            }
        }
        .onChange(of: studio.selected) { followSelection() }
        .onChange(of: studio.completedComparisonID) { if studio.completedComparisonID != nil { openCategory("models") } }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard page == .workspace else { return false }
            return studio.openDroppedAudio(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted && page == .workspace
        }
        .overlay {
            if isDropTargeted && page == .workspace { dropTarget }
        }
        .onChange(of: studio.song?.trackID) { _, trackID in
            pan = 0; tab = "section"; catalogFilter = .all; receipt = nil; studio.laneScroll = 0
            showManualHint = false
            if studyTrackID != trackID { studyStep = nil; studyTrackID = nil }
        }
        .onChange(of: studio.lastAnalysisResult?.id) {
            if let result = studio.lastAnalysisResult {
                AccessibilityNotification.Announcement(result.cancelled ? "已取消分析" : "本地分析已结束，可查看结果和状态").post()
            }
        }
        .modifier(receiptObservers)
        .alert("音乐工作台", isPresented: Binding(get: { studio.notice != nil }, set: { if !$0 { studio.notice = nil } })) {
            Button("确定") { studio.notice = nil }
        } message: { Text(studio.notice ?? "") }
    }

    private var songTitle: String? {
        studio.song.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent }
    }
    private var windowTitle: String {
        if page == .settings { return "设置" }
        return songTitle ?? "音乐分析工作台"
    }
    private var windowSubtitle: String {
        guard page == .workspace, let song = studio.song else { return "" }
        return [song.key ?? "调性待测", song.bpm.map { String(format: "%.1f BPM", $0) } ?? "BPM 待测", durationText(song.duration)]
            .joined(separator: "  ")
    }

    // MARK: Workspace

    private func workspace(_ song: SongRecord) -> some View {
        let span = song.duration / studio.zoom
        let offset = pan * (song.duration - span)
        let window = offset...(offset + span)
        return NavigationSplitView {
            CatalogSidebar(studio: studio, song: song, tab: $tab, filter: $catalogFilter, onCategory: openCategory,
                           onSelect: selectForReview, onAnalyze: { prepareAnalysis([$0], title: $0.title, wholeTrack: $0 == .lyrics) },
                           onCloud: openCloud, onAdd: add)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                workspaceGuidance(song)
                WorkspaceScopeBar(studio: studio)
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        TrackGutter(studio: studio, record: song, bars: $rulerBars)
                        TimelineCanvas(studio: studio, song: song, window: window, bars: rulerBars,
                                       inShortcut: inShortcut, outShortcut: outShortcut, onSelect: selectForReview, onResize: resize)
                    }
                    .frame(minHeight: 210, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Tone.rule.color) }
                    if studio.zoom > 1 {
                        TimelineNavigator(pan: $pan, window: window, duration: song.duration, peaks: studio.peaks)
                            .padding(.leading, CanvasLayout.gutterWidth)
                    }
                    TransportBar(studio: studio, song: song, inShortcut: inShortcut, outShortcut: outShortcut, onAdd: add)
                }
                .padding(12)
                if tab == "models" && song.cloudBatches?.contains(where: { $0.mode == "models" }) == true {
                    Divider()
                    ModelComparisonPanel(studio: studio, song: song)
                        .padding(12)
                        .frame(minHeight: 120, idealHeight: 190, maxHeight: 240)
                }
                if let result = studio.lastAnalysisResult, result.id != dismissedAnalysisResult {
                    Divider()
                    AnalysisOutcomeBar(result: result, categories: resultCategories(result, song: song), onView: { category in
                        openCategory(category.id)
                        if result.jobs.contains(.alignment) { studio.visibleKinds.insert("word") }
                    }, onDetails: { showStatus = true }, onClose: { dismissedAnalysisResult = result.id })
                }
                Divider()
                statusBar
            }
            .frame(minWidth: 380)
            .inspector(isPresented: $inspector) {
                Group {
                    if let row = studio.row {
                        ReviewInspector(studio: studio, song: song, row: row, items: reviewItems(for: row, song: song),
                                        filter: catalogFilter, autoAudition: $autoAudition, onSelect: selectForReview, onPending: { pending in
                            if !catalogFilter.includes(pending) { catalogFilter = .pending }
                            selectForReview(pending)
                        })
                        .id(row.id)
                    } else {
                        Text("在列表或时间轴选中条目后，可在这里试听和校对。")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                }
                .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
            }
        }
    }

    @ViewBuilder private func workspaceGuidance(_ song: SongRecord) -> some View {
        if let studyStep {
            StudyGuide(step: studyStep, advance: advanceStudy, close: { self.studyStep = nil })
        } else if showManualHint {
            VStack(alignment: .leading, spacing: 6) {
                Text("在波形上拖出选区，再为这段添加注释。也可以在播放头处标记一个时刻。")
                    .font(.callout)
                HStack {
                    Button("添加注释") { add("note") }.buttonStyle(.borderedProminent)
                    Button("关闭提示") { showManualHint = false }
                }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Tone.sound.color.opacity(0.08))
        } else if studio.activeJob == nil, song.marks.count == 1, song.sections.first?.source == "initial" {
            HStack(spacing: 8) {
                Button("看看歌曲结构") { prepareAnalysis([.structure], title: "看看歌曲结构", wholeTrack: true) }
                    .buttonStyle(.borderedProminent)
                    .help("找出段落与节拍，定位歌曲的变化")
                Button("整理歌词") { prepareAnalysis([.lyrics], title: "整理歌词", wholeTrack: true) }
                    .help("识别歌词，再逐句试听和校对")
                Button("自己标记片段") { showManualHint = true }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let job = studio.activeJob {
                ProgressView().controlSize(.small)
                let activity = job.title + (studio.activeAnalysisRange.map { " · " + timeRangeText($0) } ?? "")
                Text(activity).lineLimit(1).help(activity)
                Button("取消", action: studio.cancel)
            }
            if let progress = studio.cloudProgress {
                ProgressView().controlSize(.small)
                Text(progress).lineLimit(1)
                Button("取消云端", action: studio.cancelCloud)
            }
            if let status = studio.agentSendStatus {
                Text(status).lineLimit(1).help(status)
                    .accessibilityIdentifier("agentSendStatus")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let song = studio.song {
                Text("已保存 · 第 \(song.revision) 版").monospacedDigit().lineLimit(1)
                    .foregroundStyle(.secondary).accessibilityIdentifier("savedRevision")
            } else if let version = Self.appVersion {
                Text("版本 \(version)").monospacedDigit().foregroundStyle(.secondary)
            }
            Button { showStatus.toggle() } label: {
                HStack(spacing: 5) {
                    Circle().fill(serviceLamp).frame(width: 7, height: 7)
                    Text(serviceLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("分析状态与 MCP")
            .accessibilityLabel("分析状态与 MCP")
            .accessibilityValue(serviceLabel)
            .popover(isPresented: $showStatus) { statusPanel }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var serviceFailed: Bool {
        studio.serviceStatus.contains("占用") || studio.serviceStatus.hasPrefix("服务已停止")
    }
    private var serviceLamp: Color {
        studio.mcpRunning ? Tone.sound.color : serviceFailed ? .red : Color.secondary.opacity(0.5)
    }
    private var serviceLabel: String {
        studio.mcpRunning ? "MCP 在线" : serviceFailed ? "MCP 已停止" : "MCP 未启动"
    }

    private var dropTarget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Tone.sound.color.opacity(0.06))
            VStack(spacing: 14) {
                VinylOutline(lineColor: Tone.sound.color).frame(width: 150, height: 150)
                Text("松开以打开音频").font(.headline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("页面", selection: $page) {
                Text("工作区").tag(AppPage.workspace)
                Text("设置").tag(AppPage.settings)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("pageSwitcher")
        }
        ToolbarItemGroup {
            if let receipt {
                ToolbarReceipt(receipt: receipt) {
                    switch receipt.action {
                    case .status: showStatus = true
                    case .category(let category): openCategory(category)
                    case nil: break
                    }
                }
            }
            Button("打开音频", systemImage: "folder") { page = .workspace; studio.chooseFile() }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("o").accessibilityIdentifier("openAudio")
                .help("打开音频文件（⌘O）")
            if page == .workspace, studio.song != nil {
                // A running task replaces its button in place, so progress appears where it was started.
                if let job = studio.activeJob {
                    ToolbarActivity(title: "分析中 · " + job.title, detail: "正在分析 " + job.title + (studio.activeAnalysisRange.map { " · " + timeRangeText($0) } ?? ""),
                                    cancelTitle: "取消分析", cancel: studio.cancel)
                        .accessibilityIdentifier("analysisActivity")
                } else {
                    Menu {
                        Button("看看歌曲结构…") { prepareAnalysis([.structure], title: "看看歌曲结构", wholeTrack: true) }
                        Button("整理歌词…") { prepareAnalysis([.lyrics], title: "整理歌词", wholeTrack: true) }
                        Button("分析整首歌曲…") { prepareAnalysis(Studio.defaultJobs, title: "分析整首歌曲", wholeTrack: true) }
                        Menu("更多分析") {
                            ForEach(AnalysisJob.allCases.filter { $0 != .structure && $0 != .lyrics }) { job in
                                Button(job.title + "…") { prepareAnalysis([job], title: job.title) }
                            }
                        }
                    } label: { Text("分析").fixedSize() }
                    .accessibilityLabel("分析")
                    .accessibilityIdentifier("analyzeMenu")
                    .help("选择本地分析任务并检查范围与所需功能")
                }
                if studio.cloudRunning {
                    ToolbarActivity(title: "外部模型分析中", detail: studio.cloudProgress ?? "外部模型分析中",
                                    cancelTitle: "取消外部模型分析", cancel: studio.cancelCloud)
                } else {
                    Button("外部模型分析", systemImage: "sparkles") { openCloud(false) }
                        .accessibilityIdentifier("openCloudAnalysis")
                        .help("用已配置的外部模型分析选区或整首歌曲")
                }
                if studio.sendingToAgent {
                    ToolbarActivity(title: "正在发送", detail: studio.agentSendStatus ?? "正在发送给 Claude Code…")
                } else {
                    Button("导出与分享", systemImage: "square.and.arrow.up", action: openHandoff)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("handoffMenu")
                    .help("预览记录、导出 JSON，或交给 AI 助手")
                }
                Button("撤销", systemImage: "arrow.uturn.backward") {
                    if studio.undo() { confirm("已撤销上一步编辑") }
                }
                .disabled(!studio.canUndo)
                .keyboardShortcut("z")
                .help(studio.canUndo ? "撤销上一步编辑（⌘Z）" : "没有可撤销的编辑")
                Toggle(isOn: $inspector) { Label("校对卡", systemImage: "sidebar.right") }
                    .toggleStyle(.button)
                    .accessibilityIdentifier("inspectorToggle")
                    .help(inspector ? "隐藏校对卡" : "显示校对卡")
                Button("示例体验", systemImage: "questionmark.circle", action: openStudy)
                    .labelStyle(.iconOnly).help("重新打开示例体验")
                    .accessibilityIdentifier("restartStudyGuide")
            }
        }
    }

    /// Cloud and delivery confirmations are transient; local results keep their own action bar.
    private var receiptObservers: ReceiptObservers {
        ReceiptObservers(studio: studio, receiptID: receipt?.id,
                         clear: { receipt = nil },
                         cloudFinished: {
                             if studio.notice != nil {
                                 confirm("查看外部分析状态", warning: true, action: .status)
                             } else if let song = studio.song, !CatalogCategory.items("insight", in: song).isEmpty {
                                 confirm("查看解读", action: .category("insight"))
                             } else {
                                 confirm("查看外部分析状态", action: .status)
                             }
                         },
                         sendFinished: {
                             if let status = studio.agentSendStatus { confirm(status, warning: !status.contains("已读取")) }
                         })
    }

    private func confirm(_ text: String, warning: Bool = false, action: Receipt.Action? = nil) {
        receipt = Receipt(text: text, warning: warning, action: action)
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Actions

    private func openStudy() {
        guard studio.openStudy() else { return }
        studyTrackID = studio.song?.trackID
        studyStep = .locate
        showManualHint = false
        inspector = true
        openCategory("section")
    }

    private func advanceStudy() {
        guard let step = studyStep, let song = studio.song else { return }
        switch step {
        case .locate:
            guard let section = song.sections.dropFirst().first ?? song.sections.first else { return }
            studio.select(section)
            inspector = true
            studyStep = .listen(section.id)
        case .listen(let id):
            guard let section = song.sections.first(where: { $0.id == id }) else { studyStep = .locate; return }
            studio.select(section)
            studio.audition(section.timeRange)
            studyStep = .annotate(id)
        case .annotate(let id):
            guard let section = song.sections.first(where: { $0.id == id }) else { studyStep = .locate; return }
            if studio.add("note", in: section.timeRange, label: "听过这段") {
                if studio.playing { studio.togglePlayback() }
                studyStep = .finished
            }
        case .finished:
            openHandoff()
        }
    }

    private func prepareAnalysis(_ jobs: [AnalysisJob], title: String, wholeTrack: Bool = false) {
        guard studio.activeJob == nil, let song = studio.song, let scope = studio.analysisScope else { return }
        sheet = .analysis(AnalysisRequest(trackID: song.trackID, title: title, jobs: jobs, context: scope,
                                          duration: song.duration, startsWithWholeTrack: wholeTrack))
    }

    private func resultCategories(_ result: LocalAnalysisResult, song: SongRecord) -> [CatalogCategory] {
        CatalogCategory.all.filter { category in
            let completed = category.job.map { result.states[$0] == "完成" } ?? false
            return (completed || (category.id == "lyric" && result.states[.alignment] == "完成"))
                && !CatalogCategory.items(category.id, in: song).isEmpty
        }
    }

    private func openCloud(_ compare: Bool) {
        sheet = .cloud(compare: compare)
    }

    private func openHandoff() {
        if let song = studio.song { sheet = .delivery(song) }
    }

    private func openCategory(_ category: String) {
        guard let song = studio.song else { return }
        if tab != category { catalogFilter = .all }
        tab = category
        if let selected = studio.selected, !CatalogCategory.items(category, in: song).contains(where: { $0.id == selected }) {
            studio.deselect()
        }
    }

    private func selectForReview(_ mark: Mark) {
        guard let current = studio.song?.marks.first(where: { $0.id == mark.id }) else { return }
        studio.select(current)
        inspector = true
        if autoAudition { studio.audition(current.timeRange) }
    }

    /// Keep the catalog on the category that contains the selected item.
    private func followSelection() {
        guard let song = studio.song, let row = studio.row else { return }
        inspector = true
        let span = song.duration / studio.zoom
        let scrollable = song.duration - span
        let start = pan * scrollable
        if scrollable > 0, !(start...(start + span)).contains(row.start) {
            pan = min(1, max(0, (row.start - span * 0.15) / scrollable))
        }
        if CatalogCategory.items(tab, in: song).contains(where: { $0.id == row.id }) {
            if !catalogFilter.includes(row) { catalogFilter = .all }
            return
        }
        if let match = CatalogCategory.all.first(where: { category in
            category.id != "models" && CatalogCategory.items(category.id, in: song).contains { $0.id == row.id }
        }) { tab = match.id; catalogFilter = .all }
    }
    private func reviewItems(for row: Mark, song: SongRecord) -> [Mark] {
        let items = CatalogCategory.items(tab, in: song)
        if items.contains(where: { $0.id == row.id }) { return items }
        return song.marks.filter { $0.kind == row.kind }.sorted { $0.start < $1.start }
    }
    private func add(_ kind: String) {
        guard studio.add(kind) else { return }
        showManualHint = false
        openCategory(kind)
    }
    private func copyForAgent(_ song: SongRecord) -> Bool {
        do {
            let message = try song.agentMessage(mcpEndpoint: studio.mcpEndpoint)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(message, forType: .string) {
                confirm("已复制交接文本")
                return true
            } else {
                receipt = nil
                studio.notice = "写入剪贴板失败，请重试。"
            }
        } catch {
            receipt = nil
            studio.notice = error.localizedDescription
        }
        return false
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
            Text("MCP · " + studio.serviceStatus).font(.caption.monospacedDigit()).textSelection(.enabled)
        }.padding()
        }.frame(width: 460, height: 520)
    }
}

private enum WorkspaceSheet: Identifiable {
    case analysis(AnalysisRequest)
    case cloud(compare: Bool)
    // Hold the revision with the presentation, including while an analysis saves newer results.
    case delivery(SongRecord)

    var id: String {
        switch self {
        case .analysis(let request): request.id.uuidString
        case .cloud(let compare): compare ? "comparison" : "cloud"
        case .delivery(let song): "delivery-\(song.trackID)-\(song.revision)"
        }
    }
}

/// Isolates the per-frame cursor read so playback only refreshes the canvas wrapper.
private struct TimelineCanvas: View {
    let studio: Studio
    let song: SongRecord
    let window: ClosedRange<Double>
    let bars: Bool
    let inShortcut: String
    let outShortcut: String
    let onSelect: (Mark) -> Void
    let onResize: (String, Bool, Double) -> Void

    var body: some View {
        WaveformView(record: song, peaks: studio.peaks, visible: studio.visibleKinds, selected: studio.selected,
                     inPoint: studio.inPoint, outPoint: studio.outPoint, cursor: studio.cursor, window: window, snap: studio.snap,
                     inShortcut: inShortcut, outShortcut: outShortcut, onShortcut: studio.markPoint,
                     onMovePoint: studio.setPoint, onSeek: studio.seek, onPick: onSelect,
                     onRange: { studio.selection = $0; studio.seek($0.lowerBound) }, onResize: onResize, bars: bars,
                     hiddenLanes: studio.hiddenLanes, laneScroll: studio.laneScroll, onLaneScroll: { studio.laneScroll = $0 })
            .accessibilityIdentifier("waveform")
            .help("在顶部时间尺点击或拖动可定位播放头；在波形上拖动可设置出入点。")
    }
}

private struct ReceiptObservers: ViewModifier {
    let studio: Studio
    let receiptID: UUID?
    let clear: () -> Void
    let cloudFinished: () -> Void
    let sendFinished: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: receiptID) {
                guard receiptID != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { clear() }
            }
            .onChange(of: studio.cloudRunning) { was, running in if was && !running { cloudFinished() } }
            .onChange(of: studio.sendingToAgent) { was, sending in if was && !sending { sendFinished() } }
    }
}

struct Receipt: Equatable {
    enum Action: Equatable { case status, category(String) }
    let id = UUID()
    let text: String
    var warning = false
    var action: Action?
}

/// Spinner, short title and an optional cancel button that stand in for a toolbar button while its task runs.
private struct ToolbarActivity: View {
    let title: String
    let detail: String
    var cancelTitle: String?
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 170, alignment: .leading)
            if let cancel, let cancelTitle {
                Button(cancelTitle, systemImage: "xmark.circle.fill", action: cancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(cancelTitle)
            }
        }
        .padding(.horizontal, 6)
        .help(detail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(detail)
    }
}

/// A short confirmation can also open the result or status behind it.
private struct ToolbarReceipt: View {
    let receipt: Receipt
    let performAction: () -> Void

    var body: some View {
        let content = HStack(spacing: 5) {
            Image(systemName: receipt.warning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(receipt.warning ? Color.orange : Tone.sound.color)
            Text(receipt.text).lineLimit(1).truncationMode(.tail).frame(maxWidth: 240, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .help(receipt.text)
        Group {
            if receipt.action != nil {
                Button(action: performAction) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityIdentifier("toolbarReceipt")
    }
}
