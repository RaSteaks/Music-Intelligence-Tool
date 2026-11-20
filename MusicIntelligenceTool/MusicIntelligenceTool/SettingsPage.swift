import AppKit
import SwiftUI

enum AppPage: String {
    case workspace, settings
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case environment, externalModels, service, appearance, shortcuts
    var id: Self { self }
    var title: String {
        switch self {
        case .environment: "分析环境"
        case .externalModels: "外部模型"
        case .service: "MCP 服务"
        case .appearance: "外观"
        case .shortcuts: "快捷键"
        }
    }
    var icon: String {
        switch self {
        case .environment: "externaldrive"
        case .externalModels: "sparkles"
        case .service: "network"
        case .appearance: "paintpalette"
        case .shortcuts: "keyboard"
        }
    }
}

/// Settings live in the main window so switching back keeps the open song, playback and selection.
struct SettingsPage: View {
    let studio: Studio
    @SceneStorage("settingsSection") private var section = SettingsSection.environment

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: Binding(get: { section }, set: { if let next = $0 { section = next } })) {
                Label($0.title, systemImage: $0.icon).tag($0)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Group {
                switch section {
                case .environment: EnvironmentSettings(studio: studio)
                case .externalModels: ExternalModelsSettings(models: studio.externalModels)
                case .service: ServiceSettings(studio: studio)
                case .appearance: AppearanceSettings()
                case .shortcuts: ShortcutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct AppearanceSettings: View {
    @AppStorage(WavePalette.preference) private var palette = WavePalette.teal

    var body: some View {
        Form {
            Section {
                Picker("波形配色", selection: $palette) {
                    ForEach(WavePalette.allCases) { option in
                        HStack(spacing: 10) {
                            swatch(option)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("时间轴")
            } footer: {
                Text("颜色较浅的外轮廓表示峰值，较深的主体表示平均响度。概览条使用同一配色。")
            }
        }
        .formStyle(.grouped)
    }

    /// The envelope colour behind a narrower body, as the waveform draws them.
    private func swatch(_ option: WavePalette) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: option.edge).opacity(WavePalette.edgeAlpha))
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: option.body)).padding(.vertical, 5)
        }
        .frame(width: 36, height: 22)
        .background(Tone.paper.color, in: RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

private struct ServiceSettings: View {
    let studio: Studio
    @State private var copied = false
    @State private var port: Int?
    @State private var portError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("状态") {
                    Label(studio.mcpRunning ? "运行中" : "已停止", systemImage: "circle.fill")
                        .foregroundStyle(studio.mcpRunning ? .teal : .secondary)
                }
                LabeledContent("端口") {
                    if Studio.portOverride != nil {
                        Text("\(studio.mcpPort, format: .number.grouping(.never))（由 MIT_MCP_PORT 指定）")
                    } else {
                        TextField("端口", value: $port, format: .number.grouping(.never))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
                            .onSubmit(applyPort)
                        Button("应用", action: applyPort).disabled(port == studio.mcpPort)
                    }
                }
                if let portError {
                    Text(portError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("地址") {
                    Text(studio.mcpEndpoint).font(.body.monospaced()).textSelection(.enabled)
                    Button(copied ? "已拷贝" : "拷贝", action: copyEndpoint)
                }
                // When running the status is the endpoint itself; otherwise it holds the last error or exit line.
                if !studio.mcpRunning, studio.serviceStatus != "未启动" {
                    LabeledContent("最近消息") {
                        Text(studio.serviceStatus).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                }
            } header: {
                Text("MCP 服务")
            } footer: {
                Text("App 启动时自动开启，只监听本机。本机 agent 连接上面的地址后，可以读取最近一次保存的分析结果。修改端口后，agent 中登记的地址也要同步更新。")
            }
            Section {
                Button(studio.mcpRunning ? "重新启动" : "启动", action: studio.restartMCP)
                Button("在 Finder 中显示日志") { NSWorkspace.shared.activateFileViewerSelecting([studio.mcpLog]) }
                    .disabled(!FileManager.default.fileExists(atPath: studio.mcpLog.path))
            }
        }
        .formStyle(.grouped)
        .onAppear { port = studio.mcpPort }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func applyPort() {
        guard let port, (1024...65535).contains(port) else {
            portError = "请输入 1024 到 65535 之间的端口。"
            return
        }
        portError = nil
        studio.setMCPPort(port)
    }

    private func copyEndpoint() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copied = pasteboard.setString(studio.mcpEndpoint, forType: .string)
    }
}
