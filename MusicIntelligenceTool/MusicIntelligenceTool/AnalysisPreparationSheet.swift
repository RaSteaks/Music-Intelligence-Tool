import SwiftUI

struct AnalysisScope {
    enum Source: String { case selection = "手动选区", record = "所选条目", track = "整首歌曲" }
    let source: Source
    let range: ClosedRange<Double>

    var title: String { "\(source.rawValue) · \(timeRangeText(range))" }
}

extension Studio {
    var analysisScope: AnalysisScope? {
        if let selection { return AnalysisScope(source: .selection, range: selection) }
        if let row { return AnalysisScope(source: .record, range: row.timeRange) }
        return song.map { AnalysisScope(source: .track, range: 0...$0.duration) }
    }
}

func timeRangeText(_ range: ClosedRange<Double>) -> String {
    if range.lowerBound == range.upperBound { return clockText(range.lowerBound) }
    return clockText(range.lowerBound) + "–" + clockText(range.upperBound)
}

struct AnalysisRequest: Identifiable {
    let id = UUID()
    let trackID: String
    let title: String
    let jobs: [AnalysisJob]
    let context: AnalysisScope
    let duration: Double
    let startsWithWholeTrack: Bool

    var requiresWholeTrack: Bool { jobs.allSatisfy(\.requiresWholeTrack) }
}

struct AnalysisPreparationSheet: View {
    let studio: Studio
    let request: AnalysisRequest
    @Environment(\.dismiss) private var dismiss
    @State private var wholeTrack: Bool

    init(studio: Studio, request: AnalysisRequest) {
        self.studio = studio
        self.request = request
        _wholeTrack = State(initialValue: request.startsWithWholeTrack || request.requiresWholeTrack || request.context.source == .track)
    }

    private var models: ModelEnvironment { studio.modelEnvironment }
    private var scope: AnalysisScope { wholeTrack ? AnalysisScope(source: .track, range: 0...request.duration) : request.context }
    private var hasSameSong: Bool { studio.song?.trackID == request.trackID }
    private var requiresText: Bool { request.jobs.contains(.alignment) && lyricsInScope.isEmpty }
    private var lyricsInScope: [String] {
        (studio.song?.marks ?? []).compactMap { row in
            guard row.kind == "lyric", row.start >= scope.range.lowerBound, row.end <= scope.range.upperBound else { return nil }
            let field = row.fields["label"]
            return (field?.confirmed ?? field?.suggested)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
    }
    private var prerequisites: [AnalysisJob: [ModelFeature]] {
        Dictionary(uniqueKeysWithValues: request.jobs.map { job in
            let features: [ModelFeature]
            switch job {
            case .structure: features = [.base, .structure, .stems]
            case .acoustics, .rhythm, .harmony, .repetition, .events: features = [.base]
            case .lyrics: features = [.lyrics]
            case .emotion: features = [.emotion]
            case .melody: features = [.melody]
            case .alignment:
                // Use the worker's language choice so an English lyric does not require Chinese weights.
                let language = ProcessInfo.processInfo.environment["MIT_LYRIC_LANGUAGE"]?.nonEmpty
                    ?? (lyricsInScope.joined().unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) } ? "zh" : "en")
                features = language == "zh" ? [.chinese] : language == "en" ? [.english] : []
            }
            return (job, features)
        })
    }
    private var features: [ModelFeature] {
        let needed = Set(prerequisites.values.flatMap { $0 })
        return ModelFeature.allCases.filter { needed.contains($0) }
    }
    private var ready: [AnalysisJob] {
        guard hasSameSong, studio.activeJob == nil, !models.isBusy, models.checkedAt != nil,
              models.ffmpeg != nil else { return [] }
        return request.jobs.filter { job in
            (job.requiresWholeTrack || scope.range.upperBound > scope.range.lowerBound)
                && (job != .alignment || !requiresText)
                && (prerequisites[job] ?? []).allSatisfy { models.reports[$0]?.state == .ready }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title2.bold())
            Form {
                Section("分析范围") {
                    if !request.requiresWholeTrack && request.context.source != .track {
                        Picker("范围", selection: $wholeTrack) {
                            Text(request.context.source.rawValue).tag(false)
                            Text("整首歌曲").tag(true)
                        }
                        .accessibilityIdentifier("localAnalysisRangeChoice")
                    }
                    Text(scope.title).monospacedDigit().accessibilityIdentifier("localAnalysisScope")
                    if scope.source != .track && request.jobs.contains(where: \.requiresWholeTrack) {
                        Text("结构与重复关系始终按整首歌曲分析。").font(.caption).foregroundStyle(.secondary)
                    }
                    if scope.range.lowerBound == scope.range.upperBound {
                        Text("当前范围只有一个时刻。请选择整首歌曲，或返回工作区划出一段选区。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if requiresText {
                        Text("此范围没有可对齐的歌词。请先识别或填写歌词。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("所需功能") {
                    LabeledContent("FFmpeg", value: models.ffmpeg == nil ? (models.isBusy ? "正在检查" : "待安装") : "已就绪")
                    if models.ffmpeg == nil && !models.isBusy {
                        Text("安装 FFmpeg 后重新检查。可在终端运行 brew install ffmpeg。")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    ForEach(features) { feature in
                        ModelFeatureRow(models: models, feature: feature, analysisRunning: studio.activeJob != nil, showReadyDetails: false)
                    }
                    if models.cleaning || (models.isBusy && models.active.map { !features.contains($0) } == true) {
                        ProgressView("正在准备其他功能…").controlSize(.small)
                    }
                    if models.downloading {
                        Text("下载完成后，可在这里继续开始分析。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("运行目录") {
                    Text(models.directory.path).font(.caption).textSelection(.enabled)
                    if features.contains(where: { models.reports[$0]?.state == .blocked }) {
                        Text("在项目目录运行上方对应的安装命令，再选择该目录或重新检查。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("选择运行目录…") { studio.chooseRuntime(checking: features) }
                Button("重新检查所需功能") { models.refresh(features) }
            }
            .controlSize(.small)
            .disabled(models.isBusy || studio.activeJob != nil)
            if !hasSameSong {
                Text("歌曲已切换。请回到工作区重新选择分析任务。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !ready.isEmpty && ready.count < request.jobs.count {
                Text("已就绪：" + ready.map(\.title).joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("返回工作区", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !ready.isEmpty && ready.count < request.jobs.count {
                    Button("分析已就绪的 \(ready.count) 项") { start(ready) }
                }
                Button("开始分析") { start(request.jobs) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(ready.count != request.jobs.count)
                    .accessibilityIdentifier("startLocalAnalysis")
            }
        }
        .padding(20)
        .frame(width: 540, height: 480)
        .task(id: features) { if hasSameSong { models.checkIfNeeded(features: features) } }
    }

    private func start(_ jobs: [AnalysisJob]) {
        guard !jobs.isEmpty, jobs.allSatisfy(ready.contains) else { return }
        studio.run(jobs, range: scope.range)
        dismiss()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
