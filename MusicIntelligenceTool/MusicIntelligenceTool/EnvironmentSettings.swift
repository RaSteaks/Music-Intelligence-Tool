import SwiftUI

struct EnvironmentSettings: View {
    let studio: Studio
    private var models: ModelEnvironment { studio.modelEnvironment }

    var body: some View {
        Form {
            Section("本机环境") {
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("运行目录") {
                    Text(models.directory.path).lineLimit(1).truncationMode(.middle).help(models.directory.path)
                    Button("选择…", action: studio.chooseRuntime).disabled(models.isBusy)
                }
                LabeledContent("FFmpeg", value: models.ffmpeg ?? "未找到 · brew install ffmpeg")
            }
            Section {
                ForEach(ModelFeature.allCases) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title).font(.headline)
                            if let report = models.reports[feature] {
                                Text(report.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                                Label(feature == .base ? "已安装" : "已缓存", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.teal)
                            case .missing:
                                Button(report.action ?? "下载模型") { models.download(feature) }
                                    .disabled(models.isBusy || studio.activeJob != nil)
                            case .blocked:
                                Text("环境待配置").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("功能与模型")
                    Spacer()
                    Button("重新检查", action: models.refresh).disabled(models.isBusy)
                }
            } footer: {
                Text("检查只读取本机环境。点击下载后会连接模型发布源，权重保存在分析引擎使用的缓存中。")
            }
        }
        .formStyle(.grouped)
        .onAppear { if !models.isBusy { models.refresh() } }
    }
}
