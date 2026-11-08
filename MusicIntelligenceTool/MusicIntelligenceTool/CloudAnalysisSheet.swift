import SwiftUI

struct CloudAnalysisSheet: View {
    let studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var task = CloudTaskKind.interpretation
    @State private var batch = false
    @State private var compare = false
    @State private var secondConnectionID = ""
    @State private var connectionID = ""
    @State private var summaryConnectionID = ""
    @State private var start: Double
    @State private var end: Double
    @State private var firstSectionID = ""
    @State private var secondSectionID = ""
    @State private var question = ""
    @State private var sendAudio = false
    @State private var sources: Set<CloudAudioSource> = [.original]
    @State private var windowSeconds = 30.0
    @State private var maximumRequests = 20
    @State private var force = false
    @State private var error: String?

    init(studio: Studio) {
        self.studio = studio
        let range = studio.selection ?? studio.row.map { $0.start...$0.end } ?? 0...(studio.song?.duration ?? 0)
        _start = State(initialValue: range.lowerBound)
        _end = State(initialValue: range.upperBound)
    }

    private var connection: ModelConnection? { studio.externalModels.configuration.connections.first { $0.id == connectionID } }
    private var summaryConnection: ModelConnection? { studio.externalModels.configuration.connections.first { $0.id == summaryConnectionID } }
    private var usesAudio: Bool { batch ? sendAudio : task == .audio || (task == .question && sendAudio) }
    private var audioSources: [CloudAudioSource] { usesAudio ? CloudAudioSource.allCases.filter { sources.contains($0) } : [] }
    private var comparisonRanges: [AnalysisRange] {
        (studio.song?.sections.filter { $0.id == firstSectionID || $0.id == secondSectionID } ?? [])
            .map { AnalysisRange(start: $0.start, end: $0.end) }.sorted { $0.start < $1.start }
    }
    private var range: AnalysisRange {
        if !batch && task == .comparison {
            return AnalysisRange(start: comparisonRanges.first?.start ?? 0, end: comparisonRanges.last?.end ?? 0)
        }
        return AnalysisRange(start: batch ? 0 : start, end: batch ? studio.song?.duration ?? 0 : end)
    }
    private var plan: Result<CloudBatchPlan, Error> {
        Result {
            guard let song = studio.song, let connection else { throw CloudError.configuration("请先选择连接。") }
            return try CloudBatchPlan.make(song: song, connection: connection, windowSeconds: windowSeconds,
                                           audioSources: audioSources, maximumRequests: maximumRequests)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("外部模型分析").font(.title2.bold())
            Form {
                Section {
                    Toggle("整曲分段分析并汇总", isOn: $batch)
                    if !batch {
                        Toggle("同一输入使用两个模型对照", isOn: $compare)
                        Picker("任务", selection: $task) { ForEach(CloudTaskKind.allCases) { Text($0.title).tag($0) } }
                    }
                    connectionPicker("分析连接与模型", selection: $connectionID)
                    if batch { connectionPicker("最终汇总连接（仅文字）", selection: $summaryConnectionID) }
                    if compare && !batch { connectionPicker("第二个连接与模型", selection: $secondConnectionID) }
                }
                Section(batch ? "分段计划" : "分析范围") {
                    if batch {
                        TextField("最长窗口（秒）", value: $windowSeconds, format: .number)
                        Stepper("请求上限：\(maximumRequests) 次（含最终汇总）", value: $maximumRequests, in: 2...50)
                        Toggle("分段时附带音频", isOn: $sendAudio)
                    } else if task == .comparison {
                        sectionPicker("第一个段落", selection: $firstSectionID)
                        sectionPicker("第二个段落", selection: $secondSectionID)
                        Text("仅发送这两段的本地统计与已有有效解读；不发送中间段落或音频。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField("起点（原曲秒数）", value: $start, format: .number)
                        TextField("终点（原曲秒数）", value: $end, format: .number)
                    }
                    if !batch && task == .question {
                        TextField("需要核对的提示", text: $question, axis: .vertical).lineLimit(2...5)
                        Button("核对主唱与和声层次") {
                            question = "请根据实际音频区分主唱与可能的和声、叠唱层次，给出活动区间、听觉依据及不确定之处。无法区分时请明确说明，不要将分轨能量等同于声部身份。"
                            sendAudio = true
                            sources = studio.song?.stems["vocals"] == nil ? [.original] : [.vocals]
                        }
                        Toggle("附带音频核对", isOn: $sendAudio)
                        Text("提示是待核对线索；模型须说明支持或不支持的依据。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if usesAudio {
                        ForEach(CloudAudioSource.allCases) { source in
                            Toggle(source.title, isOn: Binding(get: { sources.contains(source) }, set: {
                                if $0 { sources.insert(source) } else { sources.remove(source) }
                            }))
                            .disabled(source != .original && studio.song?.stems[source.rawValue] == nil)
                        }
                        Text("仅发送勾选音轨，不额外增加前后文。分轨缺失时需先运行结构分析；分轨可能包含串音。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("发送预览") {
                    if let connection {
                        Text("接收方：\(connection.baseURL)\n模型：\(connection.model)").textSelection(.enabled)
                        if compare && !batch {
                            if let second = studio.externalModels.configuration.connections.first(where: { $0.id == secondConnectionID }) {
                                Text("第二接收方：\(second.baseURL)\n第二模型：\(second.model)")
                            }
                            Text("相同范围、音轨和记录将分别发送给两个连接，最多 2 次请求；不自动调用第三个模型作裁判。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if usesAudio {
                            Text("音频：" + audioSources.map(\.title).joined(separator: "、"))
                            if !connection.audioAvailable { Text("此模型的音频能力未知，请先在设置中测试；暂不能提交音频。 ").foregroundStyle(.orange) }
                        } else { Text("仅发送相关分析记录、歌词、人工提示及所选任务需要的已有解读，不发送音频。") }
                        if batch {
                            if let summaryConnection {
                                Text("汇总接收方：\(summaryConnection.baseURL)\n汇总模型：\(summaryConnection.model)")
                            }
                            switch plan {
                            case .success(let plan):
                                Text("\(plan.ranges.count) 个片段 + 1 次文字汇总，最多 \(plan.requestCount) 次请求；缓存命中会减少调用。")
                                DisclosureGroup("查看每段实际范围") {
                                    ForEach(plan.ranges, id: \.start) { range in
                                        Text(clockText(range.start) + " — " + clockText(range.end)).font(.caption.monospacedDigit())
                                    }
                                }
                            case .failure(let failure): Text(failure.localizedDescription).foregroundStyle(.orange)
                            }
                            Text("任一片段失败或输入变化时停止后续请求，保留已完成结果；重新运行可复用有效缓存。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if task == .comparison {
                            ForEach(comparisonRanges, id: \.start) { scope in
                                Text("所选片段：" + clockText(scope.start) + " — " + clockText(scope.end))
                            }
                        } else {
                            Text("原曲范围：" + clockText(range.start) + " — " + clockText(range.end))
                        }
                        Toggle("重新调用模型（不复用已有结果）", isOn: $force)
                    } else { Text("请先到设置 → 外部模型添加连接。") }
                    Text("按服务商规则计费，费用估算未知。请求次数上限不等于金额上限，取消也不能保证已提交请求停止计费。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("开始分析") { startAnalysis() }.buttonStyle(.borderedProminent)
                    .disabled(connection == nil || studio.cloudRunning || (usesAudio && (connection?.audioAvailable != true || audioSources.isEmpty)) || (batch && summaryConnection == nil) || (compare && !batch && secondConnectionID.isEmpty))
            }
        }.padding(20).frame(width: 650, height: 650)
        .onAppear {
            firstSectionID = studio.song?.sections.first?.id ?? ""
            secondSectionID = studio.song?.sections.dropFirst().first?.id ?? ""
            question = studio.row?.fields.keys.sorted().compactMap { studio.row?.fields[$0]?.hint }.joined(separator: "\n") ?? ""
            selectDefault()
            secondConnectionID = studio.externalModels.configuration.connections.first { $0.id != connectionID }?.id ?? ""
        }
        .onChange(of: task) { selectDefault() }
        .onChange(of: sendAudio) { selectDefault() }
        .onChange(of: batch) { selectDefault() }
    }

    private func connectionPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择连接").tag("")
            ForEach(studio.externalModels.configuration.connections) { Text($0.name + " · " + $0.model).tag($0.id) }
        }
    }

    private func sectionPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择段落").tag("")
            ForEach(studio.song?.sections ?? []) { Text(clockText($0.start) + " " + $0.label).tag($0.id) }
        }
    }

    private func selectDefault() {
        let config = studio.externalModels.configuration
        let audioID = config.audioConnectionID ?? config.connections.first?.id
        let textID = config.suggestedTextConnectionID
        connectionID = (usesAudio ? audioID : textID) ?? ""
        summaryConnectionID = textID ?? ""
        error = nil
    }

    private func startAnalysis() {
        guard let connection, let song = studio.song else { return }
        do {
            if batch {
                let plan = try plan.get()
                guard !usesAudio || !audioSources.isEmpty else { throw CloudError.configuration("请选择要发送的音轨。") }
                studio.startCloudBatch(connectionID: connectionID, summaryConnectionID: summaryConnectionID, plan: plan, force: force)
            } else {
                let scopes = task == .comparison ? comparisonRanges : [range]
                let includePrevious = [.comparison, .overview].contains(task)
                let options = CloudTaskOptions(question: task == .question ? question : "", focusRanges: task == .comparison ? scopes : [],
                                               audioSources: audioSources, inputInsightIDs: includePrevious ? song.currentInsightIDs(in: scopes) : [],
                                               compactContext: includePrevious,
                                               missingRanges: task == .overview ? song.unanalyzedRanges(in: range) : [])
                try options.validate(task: task, range: range, duration: song.duration)
                if usesAudio && range.duration * Double(audioSources.count) > connection.maxAudioSeconds {
                    throw CloudError.configuration("所选音轨合计时长超过 \(Int(connection.maxAudioSeconds)) 秒，请缩小选区或减少音轨。")
                }
                try studio.externalModels.assign(connectionID, to: usesAudio ? .audio : .interpretation)
                if compare {
                    studio.compareModels(connectionIDs: [connectionID, secondConnectionID], task: task, range: range, options: options, force: force)
                } else { studio.startCloud(connectionID: connectionID, task: task, range: range, force: force, options: options) }
            }
            if studio.cloudRunning { dismiss() } else { error = studio.notice }
        } catch { self.error = error.localizedDescription }
    }
}
