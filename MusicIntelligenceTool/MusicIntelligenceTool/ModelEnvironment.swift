import CryptoKit
import Darwin
import Foundation
import Observation

enum ModelFeature: String, Codable, CaseIterable, Identifiable {
    case base, structure, stems, melody, lyrics, chinese = "align-zh", english = "align-en", emotion
    var id: Self { self }
    var title: String {
        switch self {
        case .base: "声学、和声与 MCP"
        case .structure: "结构、节拍与小节第一拍"
        case .stems: "声部分离"
        case .melody: "主导旋律与音域"
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
        case .melody: ".venv-music"
        }
    }
    var setupCommand: String {
        switch self {
        case .base, .lyrics: "./script/setup.sh"
        case .structure, .stems, .emotion: "./script/setup.sh models"
        case .chinese, .english: "./script/setup.sh align"
        case .melody: "./script/setup.sh music"
        }
    }
}

struct EnvironmentReport: Codable {
    enum State: String, Codable { case ready, missing, blocked }
    struct Weight: Codable {
        var name: String
        var bytes: Int64?
        var source: String
        var url: URL?
    }
    var state: State
    var detail: String
    var action: String?
    var python: String?
    var weights: [Weight]?
}

@Observable @MainActor
final class ModelEnvironment {
    private(set) var directory: URL
    private(set) var reports: [ModelFeature: EnvironmentReport] = [:]
    private(set) var errors: [ModelFeature: String] = [:]
    private(set) var active: ModelFeature?
    private(set) var downloading = false
    private(set) var stopping = false
    private(set) var progress = ""
    private(set) var ffmpeg: String?
    private(set) var checkedAt: Date?
    private(set) var cacheError: String?
    private let cacheDirectory: URL
    private var process: Process?
    var isBusy: Bool { active != nil }

    private struct Snapshot: Codable {
        var reports: [ModelFeature: EnvironmentReport]
        var errors: [ModelFeature: String]
        var ffmpeg: String?
        var checkedAt: Date
    }

    init(directory: URL = Runtime.root, cacheDirectory: URL) {
        self.directory = directory.standardizedFileURL
        self.cacheDirectory = cacheDirectory
        restoreSnapshot()
    }

    func checkIfNeeded(in directory: URL? = nil) {
        guard !isBusy else { return }
        if let directory = directory?.standardizedFileURL, directory != self.directory {
            self.directory = directory
            reports.removeAll()
            errors.removeAll()
            ffmpeg = nil
            checkedAt = nil
            cacheError = nil
            restoreSnapshot()
        }
        // A completed check has no expiry: page navigation must not launch model processes again.
        if checkedAt == nil { refresh() }
        else {
            let missing = ModelFeature.allCases.filter { reports[$0] == nil }
            if !missing.isEmpty { start(missing, download: false) }
        }
    }

    func refresh() {
        guard !isBusy else { return }
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
            defer {
                // Keep the last complete snapshot if the app quits during a check or download.
                if !stopping {
                    if !download { checkedAt = Date() }
                    saveSnapshot()
                }
                process = nil; active = nil; downloading = false; stopping = false; progress = ""
            }
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

    private var cacheURL: URL {
        let key = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(key).appendingPathComponent("check.json")
    }

    private func restoreSnapshot() {
        // Missing or incompatible saved data is a cache miss; a fresh check replaces it.
        guard let data = try? Data(contentsOf: cacheURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        reports = snapshot.reports
        errors = snapshot.errors
        ffmpeg = snapshot.ffmpeg
        checkedAt = snapshot.checkedAt
    }

    private func saveSnapshot() {
        guard let checkedAt else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let snapshot = Snapshot(reports: reports, errors: errors, ffmpeg: ffmpeg, checkedAt: checkedAt)
            try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
            cacheError = nil
        } catch {
            cacheError = "检查结果未能保存：" + error.localizedDescription
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
                                    feature.rawValue, directory.path], python: interpreter, root: directory)
        let output = Pipe()
        p.standardOutput = output
        let logs = cacheURL.deletingLastPathComponent().appendingPathComponent("Logs")
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
        for try await data in Self.eventLines(from: output.fileHandleForReading) {
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

    private static func eventLines(from reader: FileHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { stream in
            // On macOS an idle MCP bytes.lines read can stall other FileHandle.AsyncBytes
            // readers. Drain this child independently and deliver progress before it exits.
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 8192)
                var line = Data()
                while true {
                    let count = read(reader.fileDescriptor, &buffer, buffer.count)
                    if count < 0 {
                        let code = errno
                        if code == EINTR { continue }
                        stream.finish(throwing: NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
                        return
                    }
                    if count == 0 {
                        if !line.isEmpty { stream.yield(line) }
                        stream.finish()
                        return
                    }
                    // A read may split a UTF-8 character or contain several JSON events.
                    var bytes = buffer.prefix(count)
                    while let newline = bytes.firstIndex(of: 0x0A) {
                        line.append(contentsOf: bytes[..<newline])
                        stream.yield(line)
                        line.removeAll(keepingCapacity: true)
                        bytes = bytes.suffix(from: newline + 1)
                    }
                    line.append(contentsOf: bytes)
                }
            }
        }
    }
}
