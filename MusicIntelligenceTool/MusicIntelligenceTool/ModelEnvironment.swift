import Foundation
import Observation

enum ModelFeature: String, CaseIterable, Identifiable {
    case base, structure, stems, lyrics, chinese = "align-zh", english = "align-en", emotion
    var id: Self { self }
    var title: String {
        switch self {
        case .base: "声学、和声与 MCP"
        case .structure: "结构、节拍与小节第一拍"
        case .stems: "声部分离"
        case .lyrics: "歌词转录"
        case .chinese: "中文字词对齐"
        case .english: "英文字词对齐"
        case .emotion: "情绪标签与走势"
        }
    }
    var environment: String {
        switch self {
        case .base, .lyrics: ".venv"
        case .structure, .stems: ".venv-structure"
        case .chinese, .english: ".venv-align"
        case .emotion: ".venv-emotion"
        }
    }
    var setupCommand: String {
        switch self {
        case .base, .lyrics: "./script/setup.sh"
        case .structure, .stems, .emotion: "./script/setup.sh models"
        case .chinese, .english: "./script/setup.sh align"
        }
    }
}

struct EnvironmentReport: Decodable {
    enum State: String, Decodable { case ready, missing, blocked }
    var state: State
    var detail: String
    var action: String?
    var python: String?
}

@Observable @MainActor
final class ModelEnvironment {
    private(set) var directory = Runtime.root
    private(set) var reports: [ModelFeature: EnvironmentReport] = [:]
    private(set) var errors: [ModelFeature: String] = [:]
    private(set) var active: ModelFeature?
    private(set) var downloading = false
    private(set) var stopping = false
    private(set) var progress = ""
    private(set) var ffmpeg: String?
    private var process: Process?
    var isBusy: Bool { active != nil }

    func refresh() {
        guard !isBusy else { return }
        directory = Runtime.root
        reports.removeAll()
        errors.removeAll()
        let paths = [directory.appendingPathComponent(".venv/bin").path] + Runtime.toolPath.components(separatedBy: ":")
        ffmpeg = paths.map { $0 + "/ffmpeg" }.first(where: FileManager.default.isExecutableFile(atPath:))
        start(ModelFeature.allCases, download: false)
    }

    func download(_ feature: ModelFeature) {
        guard !isBusy, reports[feature]?.action != nil else { return }
        start([feature], download: true)
    }

    private func start(_ features: [ModelFeature], download: Bool) {
        downloading = download
        active = features.first
        Task {
            defer { process = nil; active = nil; downloading = false; stopping = false; progress = "" }
            for feature in features {
                if stopping { break }
                active = feature
                progress = download ? "正在准备下载…" : "正在检查本地文件…"
                errors[feature] = nil
                do {
                    let report = try await run(feature, download: download)
                    if !stopping { reports[feature] = report }
                } catch {
                    if !stopping { errors[feature] = error.localizedDescription }
                    // Keep a missing model's action available for retry after a failed download.
                    if reports[feature] == nil {
                        reports[feature] = EnvironmentReport(state: .blocked, detail: "请检查此功能的 Python 环境")
                    }
                }
                if stopping, download { errors[feature] = "下载已取消，可重新下载或检查缓存。" }
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        stopping = true
        if process?.isRunning == true { process?.interrupt() }
    }

    private func run(_ feature: ModelFeature, download: Bool) async throws -> EnvironmentReport {
        let interpreter = feature.environment + "/bin/python"
        guard FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent(interpreter).path) else {
            return EnvironmentReport(state: .blocked, detail: "未找到 \(feature.environment)/bin/python")
        }
        let p = try Runtime.process("model_environment", args: [download ? "download" : "check",
                                    feature.rawValue, directory.path], python: interpreter)
        let output = Pipe()
        p.standardOutput = output
        let logs = URL.cachesDirectory.appendingPathComponent("MusicIntelligenceTool/Environment")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent(feature.rawValue + ".log")
        try Data().write(to: log)
        let diagnostics = try FileHandle(forWritingTo: log)
        defer { try? diagnostics.close() }
        p.standardError = diagnostics
        try p.run()
        process = p
        try output.fileHandleForWriting.close()
        var report: EnvironmentReport?
        var failure: String?
        for try await line in output.fileHandleForReading.bytes.lines {
            let data = Data(line.utf8)
            if let message = try? JSONDecoder().decode([String: String].self, from: data) {
                if let step = message["progress"] { progress = step }
                if let error = message["error"] { failure = error }
            }
            if let result = try? JSONDecoder().decode(EnvironmentReport.self, from: data) { report = result }
        }
        if let failure { throw StudioError.message(failure + "\n日志：" + log.path) }
        guard let report else { throw StudioError.message("进程未返回检查结果。日志：\(log.path)") }
        return report
    }
}
