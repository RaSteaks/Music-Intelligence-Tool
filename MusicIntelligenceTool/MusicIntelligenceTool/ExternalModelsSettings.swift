import SwiftUI

struct ExternalModelsSettings: View {
    let models: ExternalModels
    @State private var selected: String?
    @State private var draft = ModelConnection()
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var catalog: [CloudModel] = []
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var confirmDelete = false

    var body: some View {
        HSplitView {
            VStack {
                List(models.configuration.connections, selection: $selected) { connection in
                    VStack(alignment: .leading) {
                        Text(connection.name)
                        Text(connection.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(connection.id)
                }
                Button("新建连接", systemImage: "plus") {
                    selected = nil; draft = ModelConnection(); apiKey = ""; catalog = []; message = nil
                }.padding(10)
            }.frame(minWidth: 160, idealWidth: 190, maxWidth: 250)
            Form {
                if let error = models.loadError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Section("连接") {
                    TextField("连接名称", text: $draft.name)
                    Picker("接入渠道", selection: $draft.provider) {
                        ForEach(CloudProvider.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Base URL", text: $draft.baseURL)
                        .help("填写 API 基础地址，不包含 /chat/completions 或 /responses。")
                    HStack {
                        if showKey { TextField("新的 API Key", text: $apiKey) }
                        else { SecureField("新的 API Key", text: $apiKey) }
                        Button(showKey ? "隐藏密钥" : "显示密钥", systemImage: showKey ? "eye.slash" : "eye") { showKey.toggle() }
                            .labelStyle(.iconOnly)
                    }
                    Text("密钥保存在 macOS 钥匙串。同一 API 来源可留空沿用密钥，更换来源时请重新输入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("模型与接口") {
                    HStack {
                        TextField("模型 ID", text: $draft.model).accessibilityIdentifier("cloudModelID")
                        Button("获取模型") { fetchModels() }
                    }
                    if !catalog.isEmpty {
                        Picker("可用模型", selection: $draft.model) {
                            Text("手动填写").tag(draft.model)
                            ForEach(catalog.filter { $0.id != draft.model }) { model in
                                Text(model.id + (model.supportsAudio == true ? " · 音频输入" : "")).tag(model.id)
                            }
                        }
                    }
                    Picker("接口", selection: $draft.apiStyle) {
                        ForEach(CloudAPIStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("结果格式", selection: $draft.outputMode) {
                        ForEach(CloudOutputMode.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.provider == .openAI && draft.apiStyle == .chat {
                        Toggle("兼容旧版 max_tokens 参数", isOn: $draft.legacyTokenLimit)
                            .help("仅在兼容服务不接受 max_completion_tokens 时启用。")
                    }
                    Text("模型列表不等同于调用权限。音频模型不一定支持严格 JSON Schema，可选提示词 JSON 并在本地校验。")
                        .font(.caption).foregroundStyle(.secondary)
                    if draft.provider == .openRouter {
                        TextField("固定上游服务商（可选）", text: $draft.upstream)
                        Toggle("允许同一模型在服务商之间回退", isOn: $draft.allowProviderFallbacks)
                        Text("留空由 OpenRouter 选择上游；固定时使用 only 限定。应用不会自动切换模型或接入渠道。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("调用限制") {
                    TextField("最大输出 token", value: $draft.maxOutputTokens, format: .number.grouping(.never))
                    TextField("单次音频上限（秒）", value: $draft.maxAudioSeconds, format: .number)
                    TextField("超时（秒）", value: $draft.timeoutSeconds, format: .number)
                    Text("另有 20 MB 音频及 512 KB 分析记录上限。费用以服务商账单为准；失败不自动重试。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("保存与能力验证") {
                    Button("保存连接") { save() }.buttonStyle(.borderedProminent).accessibilityIdentifier("saveCloudConnection")
                    HStack {
                        Button("测试文字请求（使用额度）") { verify(.interpretation) }
                        Button("测试音频请求（使用额度）") { verify(.audio) }
                    }
                    Text("测试会先保存配置。音频测试仅发送内置的一秒合成音，不使用当前歌曲。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("文字：" + (draft.verifiedTextAt == nil ? "未验证" : "请求已验证"))
                    Text("音频：" + (draft.verifiedAudioAt != nil ? "请求已验证" : draft.audioAvailable ? "目录声明支持" : "未验证"))
                    if busy { ProgressView("正在请求…") }
                    if let message { Text(message).font(.callout).textSelection(.enabled).accessibilityIdentifier("cloudConnectionStatus") }
                }
                if selected != nil {
                    Section {
                        Button("删除此连接及密钥", role: .destructive) { confirmDelete = true }
                    }
                }
            }.formStyle(.grouped).frame(minWidth: 460)
        }
        .disabled(busy || models.loadError != nil)
        .onAppear { if let first = models.configuration.connections.first { selected = first.id; load(first.id) } }
        .onChange(of: selected) { _, id in if let id { load(id) } }
        .onChange(of: draft.provider) { old, next in
            if draft.baseURL == old.baseURL {
                draft.baseURL = next.baseURL
                draft.apiStyle = next == .openRouter ? .responses : .chat
            }
        }
        .onChange(of: draft.credentialOrigin) {
            apiKey = ""
            catalog = []
            let saved = models.configuration.connections.first { $0.id == draft.id }
            if saved?.credentialOrigin != draft.credentialOrigin {
                draft.verifiedTextAt = nil
                draft.verifiedAudioAt = nil
            }
        }
        .onChange(of: draft.model) { _, id in
            if catalog.isEmpty, models.configuration.connections.contains(where: { $0.id == draft.id && $0.model == id }) { return }
            draft.declaredAudio = catalog.first { $0.id == id }?.supportsAudio
            draft.declaredSchema = catalog.first { $0.id == id }?.supportsSchema
            draft.catalogSignature = draft.validationSignature
        }
        .onDisappear { operation?.cancel() }
        .confirmationDialog("删除此连接及钥匙串密钥？歌曲中的分析记录会保留。", isPresented: $confirmDelete) {
            Button("删除连接及密钥", role: .destructive) {
                do { try models.delete(draft.id); selected = nil; draft = ModelConnection(); apiKey = ""; message = "连接已删除。" }
                catch { message = error.localizedDescription }
            }
        }
    }

    private func load(_ id: String) {
        guard let connection = models.configuration.connections.first(where: { $0.id == id }) else { return }
        draft = connection; apiKey = ""; catalog = []; message = nil
    }

    @discardableResult private func save() -> Bool {
        do {
            try models.save(draft, newKey: apiKey)
            apiKey = ""
            selected = draft.id
            draft = models.configuration.connections.first { $0.id == draft.id } ?? draft
            message = "连接已保存。"
            return true
        } catch { message = error.localizedDescription; return false }
    }

    private func fetchModels() {
        let connection = draft
        busy = true; message = nil
        operation = Task {
            defer { busy = false }
            do {
                let key = try apiKey.isEmpty ? models.key(for: connection) : apiKey
                catalog = try await CloudClient().models(connection: connection, key: key)
                draft.declaredAudio = catalog.first { $0.id == draft.model }?.supportsAudio
                draft.declaredSchema = catalog.first { $0.id == draft.model }?.supportsSchema
                draft.catalogSignature = draft.validationSignature
                message = "获取到 \(catalog.count) 个模型。请选择或填写模型 ID；调用能力需单独验证。"
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    private func verify(_ task: CloudTaskKind) {
        guard save() else { return }
        let connection = draft
        busy = true; message = nil
        operation = Task {
            defer { busy = false }
            do {
                let context = CloudContext(range: AnalysisRange(start: 0, end: 1), status: [:], items: [
                    CloudContext.Item(id: "test", kind: "note", start: 0, end: 1, source: "test",
                                      fields: ["label": .init(confirmed: "能力测试素材：一秒 440 Hz 合成音")], metrics: [:])
                ])
                _ = try await CloudClient().analyze(connection: connection, key: models.key(for: connection), context: context,
                                                   task: task, audio: task == .audio ? CloudAudio.testWAV() : nil)
                try Task.checkCancellation()
                try models.recordVerification(connection, task: task)
                draft = models.configuration.connections.first { $0.id == connection.id } ?? draft
                message = "测试请求通过。仅验证接口和结果格式，不代表音乐判断准确。"
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
