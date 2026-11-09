import SwiftUI
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
    @State private var showHandoff = false
    /// Frozen when the preview opens, so what is shown is exactly what is sent or copied,
    /// even if analysis saves a new revision or an MCP request switches songs meanwhile.
    @State private var handoffSnapshot: SongRecord?
    /// A short confirmation shown in the toolbar after an action finishes, next to where it was started.
    @State private var receipt: Receipt?
    /// Analysis jobs seen during the current run, summarised when the run ends.
    @State private var batchJobs: [AnalysisJob] = []
    @State private var isDropTargeted = false
    @AppStorage("rulerBars") private var rulerBars = false
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
                EmptyStage(studio: studio)
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .background { PlaybackClock(studio: studio, playing: studio.playing).frame(width: 0, height: 0) }
        .toolbar { toolbar }
        .frame(minWidth: 830, minHeight: 580)
        .sheet(isPresented: $showCloudAnalysis) { CloudAnalysisSheet(studio: studio) }
        .sheet(isPresented: $showHandoff) {
            if let song = handoffSnapshot { HandoffSheet(studio: studio, song: song, onCopy: { copyForAgent(song) }) }
        }
        .onChange(of: studio.selected) { followSelection() }
        .onChange(of: studio.completedComparisonID) { if studio.completedComparisonID != nil { tab = "models" } }
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
        .onChange(of: studio.song?.trackID) { pan = 0; tab = "section"; receipt = nil; studio.laneScroll = 0 }
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
            CatalogSidebar(studio: studio, song: song, tab: $tab)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        TrackGutter(studio: studio, record: song, bars: $rulerBars)
                        TimelineCanvas(studio: studio, song: song, window: window, bars: rulerBars,
                                       inShortcut: inShortcut, outShortcut: outShortcut, onResize: resize)
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
                if tab == "models" {
                    Divider()
                    ModelComparisonPanel(studio: studio, song: song)
                        .padding(12)
                        .frame(height: 260)
                }
                Divider()
                statusBar
            }
            .frame(minWidth: 380)
            .inspector(isPresented: $inspector) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let row = studio.row {
                            ReviewCard(studio: studio, song: song, row: row).id(row.id)
                        } else {
                            Text("选择一个段落或标注开始校对。").foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let job = studio.activeJob {
                ProgressView().controlSize(.small)
                Text(job.title).lineLimit(1)
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
            if let version = Self.appVersion {
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
                ToolbarReceipt(receipt: receipt) { showStatus = true }
            }
            Button("打开音频", systemImage: "folder") { page = .workspace; studio.chooseFile() }
                .keyboardShortcut("o").accessibilityIdentifier("openAudio")
                .help("打开音频文件（⌘O）")
            if page == .workspace, studio.song != nil {
                // A running task replaces its button in place, so progress appears where it was started.
                if let job = studio.activeJob {
                    ToolbarActivity(title: "分析中 · " + job.title, detail: "正在分析：" + job.title,
                                    cancelTitle: "取消分析", cancel: studio.cancel)
                        .accessibilityIdentifier("analysisActivity")
                } else {
                    Menu {
                        Button("分析整首歌曲") { studio.run(Studio.defaultJobs) }
                        Divider()
                        ForEach(AnalysisJob.allCases) { job in
                            Button(job.title) { studio.run([job], range: studio.selection ?? studio.row.map { $0.start...$0.end }) }
                        }
                    } label: { Label("分析", systemImage: "waveform.badge.magnifyingglass") }
                    .disabled(studio.modelEnvironment.isModifyingFiles)
                    .accessibilityLabel("分析")
                    .accessibilityIdentifier("analyzeMenu")
                    .help(studio.modelEnvironment.isModifyingFiles ? "模型正在下载或清理，完成后才能分析"
                          : "本地分析：整首歌曲，或只分析当前选区")
                }
                if studio.cloudRunning {
                    ToolbarActivity(title: "外部模型分析中", detail: studio.cloudProgress ?? "外部模型分析中",
                                    cancelTitle: "取消外部模型分析", cancel: studio.cancelCloud)
                } else {
                    Button("外部模型分析", systemImage: "sparkles") { showCloudAnalysis = true }
                        .accessibilityIdentifier("openCloudAnalysis")
                        .help("用已配置的外部模型分析选区或整首歌曲")
                }
                if studio.sendingToAgent {
                    ToolbarActivity(title: "正在发送", detail: studio.agentSendStatus ?? "正在发送给 Claude Code…")
                } else {
                    Menu {
                        Button("发送给 Claude Code…") { handoffSnapshot = studio.song; showHandoff = handoffSnapshot != nil }
                        Button("复制交接文本") { copyForAgent() }
                        Divider()
                        Button("导出 JSON…") {
                            if let url = studio.exportJSON() { confirm("已导出 " + url.lastPathComponent) }
                        }
                    } label: { Label("交给 agent", systemImage: "paperplane") }
                    .accessibilityIdentifier("handoffMenu")
                    .accessibilityLabel("交给 agent")
                    .help("发送或复制分析记录给 agent，或导出 JSON")
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
            }
        }
    }

    /// Turns the end of a background task into a toolbar confirmation, and clears it after a few seconds.
    private var receiptObservers: ReceiptObservers {
        ReceiptObservers(studio: studio, receiptID: receipt?.id,
                         clear: { receipt = nil },
                         jobChanged: { job in
                             if let job { if !batchJobs.contains(job) { batchJobs.append(job) } } else { summarizeAnalysis() }
                         },
                         cloudFinished: {
                             confirm(studio.notice == nil ? "外部模型分析已结束" : "外部模型分析未完成", warning: studio.notice != nil)
                         },
                         sendFinished: {
                             if let status = studio.agentSendStatus { confirm(status, warning: !status.contains("已读取")) }
                         })
    }

    private func confirm(_ text: String, warning: Bool = false, opensStatus: Bool = false) {
        receipt = Receipt(text: text, warning: warning, opensStatus: opensStatus)
        AccessibilityNotification.Announcement(text).post()
    }

    /// One confirmation per run, however many jobs it contained.
    private func summarizeAnalysis() {
        guard !batchJobs.isEmpty else { return }
        let jobs = batchJobs
        batchJobs = []
        let states = jobs.map { studio.song?.status[$0.rawValue] ?? "" }
        let failed = states.filter { $0.hasPrefix("失败") }.count
        if states.contains("已取消") {
            confirm("已取消分析", warning: true)
        } else if failed > 0 {
            confirm("分析结束，\(failed) 项失败，点此查看", warning: true, opensStatus: true)
        } else {
            confirm(jobs.count == 1 ? jobs[0].title + " 分析完成" : "分析完成，共 \(jobs.count) 项")
        }
    }

    // MARK: Actions

    /// Keep the catalog on the category that contains the selected item.
    private func followSelection() {
        guard let song = studio.song, let row = studio.row else { return }
        if CatalogCategory.items(tab, in: song).contains(where: { $0.id == row.id }) { return }
        if let match = CatalogCategory.all.first(where: { category in
            category.id != "models" && CatalogCategory.items(category.id, in: song).contains { $0.id == row.id }
        }) { tab = match.id }
    }
    private func add(_ kind: String) {
        studio.add(kind)
        if kind != "section" { tab = kind }
    }
    private func copyForAgent(_ snapshot: SongRecord? = nil) {
        guard let song = snapshot ?? studio.song else { return }
        do {
            let message = try song.agentMessage(mcpEndpoint: studio.mcpEndpoint)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(message, forType: .string) {
                confirm("已复制，可粘贴给 agent")
            } else {
                receipt = nil
                studio.notice = "写入剪贴板失败，请重试。"
            }
        } catch {
            receipt = nil
            studio.notice = error.localizedDescription
        }
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

/// Isolates the per-frame cursor read so playback only refreshes the canvas wrapper.
private struct TimelineCanvas: View {
    let studio: Studio
    let song: SongRecord
    let window: ClosedRange<Double>
    let bars: Bool
    let inShortcut: String
    let outShortcut: String
    let onResize: (String, Bool, Double) -> Void

    var body: some View {
        WaveformView(record: song, peaks: studio.peaks, visible: studio.visibleKinds, selected: studio.selected,
                     inPoint: studio.inPoint, outPoint: studio.outPoint, cursor: studio.cursor, window: window, snap: studio.snap,
                     inShortcut: inShortcut, outShortcut: outShortcut, onShortcut: studio.markPoint,
                     onMovePoint: studio.setPoint, onSeek: studio.seek, onPick: studio.select,
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
    let jobChanged: (AnalysisJob?) -> Void
    let cloudFinished: () -> Void
    let sendFinished: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: receiptID) {
                guard receiptID != nil else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { clear() }
            }
            .onChange(of: studio.activeJob) { _, job in jobChanged(job) }
            .onChange(of: studio.cloudRunning) { was, running in if was && !running { cloudFinished() } }
            .onChange(of: studio.sendingToAgent) { was, sending in if was && !sending { sendFinished() } }
    }
}

struct Receipt: Equatable {
    let id = UUID()
    let text: String
    var warning = false
    var opensStatus = false
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

/// The result of the last action, held for a few seconds. A warning that has details opens the status panel.
private struct ToolbarReceipt: View {
    let receipt: Receipt
    let openStatus: () -> Void

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
            if receipt.opensStatus {
                Button(action: openStatus) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityIdentifier("toolbarReceipt")
    }
}
