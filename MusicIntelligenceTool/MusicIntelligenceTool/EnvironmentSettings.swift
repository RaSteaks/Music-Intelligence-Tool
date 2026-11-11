import SwiftUI

struct EnvironmentSettings: View {
    let studio: Studio
    @State private var cleanupRequest: ModelCleanup?
    private var models: ModelEnvironment { studio.modelEnvironment }

    var body: some View {
        Form {
            Section("本机环境") {
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("运行目录") {
                    Text(models.directory.path).lineLimit(1).truncationMode(.middle).help(models.directory.path)
                    Button("选择…") { studio.chooseRuntime() }.disabled(models.isBusy || studio.activeJob != nil)
                }
                LabeledContent("FFmpeg", value: models.ffmpeg ?? "未找到 · brew install ffmpeg")
            }
            Section {
                ForEach(ModelFeature.allCases) { feature in
                    ModelFeatureRow(models: models, feature: feature, analysisRunning: studio.activeJob != nil)
                }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("功能与模型")
                        Spacer()
                        Menu("清理") {
                            Button("清理模型缓存…") { cleanupRequest = .models }
                            Button("清理模型和运行环境…") { cleanupRequest = .modelsAndEnvironment }
                        }
                        .fixedSize()
                        .disabled(models.isBusy || studio.activeJob != nil)
                        Button("重新检查") { models.refresh() }.disabled(models.isBusy)
                    }
                    if models.cleaning {
                        ProgressView("正在清理…").controlSize(.small)
                    }
                    if let status = models.cleanupStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let checkedAt = models.checkedAt {
                        Text("上次检查：\(checkedAt.formatted(date: .numeric, time: .shortened))。点击“重新检查”更新。")
                    }
                    Text("所列大小为完整权重大小，配置文件和 Python 依赖另计。检查仅使用本地文件，下载时会复用已有缓存。")
                    if let cacheError = models.cacheError {
                        Text(cacheError).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(cleanupRequest?.title ?? "清理", isPresented: Binding(
            get: { cleanupRequest != nil }, set: { if !$0 { cleanupRequest = nil } }
        ), presenting: cleanupRequest) { scope in
            Button("移到废纸篓", role: .destructive) { studio.cleanEnvironment(scope) }
            Button("取消", role: .cancel) { }
        } message: { scope in
            let shared = "将此 App 使用的模型缓存移到废纸篓。共用这些缓存的其他工具可能需要重新下载。歌曲和分析结果会保留。"
            if scope == .modelsAndEnvironment {
                Text("\(shared)\n\n这也会停止 MCP 服务，并移除当前运行目录中的 Python 虚拟环境和 Music2Emotion 安装。\n\(models.directory.path)")
            } else {
                Text(shared)
            }
        }
        .onAppear { models.checkIfNeeded() }
    }
}

/// The task sheet and Settings use the same prerequisite status and download controls.
struct ModelFeatureRow: View {
    let models: ModelEnvironment
    let feature: ModelFeature
    let analysisRunning: Bool
    var showReadyDetails = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title).font(.headline)
                if let report = models.reports[feature], showReadyDetails || report.state != .ready {
                    Text(report.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    ForEach(report.weights ?? [], id: \.name) { weight in
                        let size = weight.bytes?.formatted(.byteCount(style: .decimal)) ?? "大小未知"
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(weight.name) · \(size)")
                            if let url = weight.url {
                                Link(weight.source, destination: url)
                                    .help(url.absoluteString)
                            } else {
                                Text(weight.source)
                            }
                        }
                        .font(.caption)
                    }
                    if report.state == .blocked {
                        Text(feature.setupCommand).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let python = report.python {
                        Text("Python \(python) · \(feature.environment)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if models.active == feature {
                    Text(models.stopping ? "正在取消…" : models.progress)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = models.errors[feature] {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Spacer()
            if models.active == feature {
                ProgressView().controlSize(.small)
                if models.downloading {
                    Button("取消", action: models.cancel).disabled(models.stopping)
                }
            } else if let report = models.reports[feature] {
                switch report.state {
                case .ready:
                    Label(feature == .base || feature == .melody ? "已安装" : "已缓存", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.teal)
                case .missing:
                    Button(report.action ?? "下载模型") { models.download(feature) }
                        .disabled(models.isBusy || analysisRunning)
                case .blocked:
                    Text("环境待配置").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
