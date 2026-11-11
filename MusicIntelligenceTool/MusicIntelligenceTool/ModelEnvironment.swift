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
    private(set) var cleaning = false
    private(set) var cleanupStatus: String?
    private(set) var stopping = false
    private(set) var progress = ""
    private(set) var ffmpeg: String?
    private(set) var checkedAt: Date?
    private(set) var cacheError: String?
    private let cacheDirectory: URL
    private var process: Process?
    var isBusy: Bool { active != nil || cleaning }
    var isModifyingFiles: Bool { downloading || cleaning }

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

    func checkIfNeeded(in directory: URL? = nil, features: [ModelFeature] = ModelFeature.allCases) {
        guard !isBusy else { return }
        if let directory = directory?.standardizedFileURL, directory != self.directory {
            self.directory = directory
            reports.removeAll()
            errors.removeAll()
            ffmpeg = nil
            checkedAt = nil
            cacheError = nil
            cleanupStatus = nil
            restoreSnapshot()
        }
        // A task checks only its prerequisites. Settings fills in any features not checked yet.
        let missing = checkedAt == nil ? features : features.filter { reports[$0] == nil }
        if !missing.isEmpty || checkedAt == nil { refresh(missing) }
    }

    func refresh(_ features: [ModelFeature] = ModelFeature.allCases) {
        guard !isBusy else { return }
        for feature in features {
            reports[feature] = nil
            errors[feature] = nil
        }
        let paths = [directory.appendingPathComponent(".venv/bin").path] + Runtime.toolPath.components(separatedBy: ":")
        ffmpeg = paths.map { $0 + "/ffmpeg" }.first(where: FileManager.default.isExecutableFile(atPath:))
        if features.isEmpty {
            checkedAt = Date()
            saveSnapshot()
        } else {
            start(features, download: false)
        }
    }

    func download(_ feature: ModelFeature) {
        guard !isBusy, reports[feature]?.action != nil else { return }
        start([feature], download: true)
    }

    func clean(_ scope: ModelCleanup, stopMCP: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        cleaning = true
        cleanupStatus = nil
        let runtime = directory
        Task {
            do {
                try invalidateSavedChecks()
                checkedAt = nil
                if scope == .modelsAndEnvironment { try await stopMCP() }
                cleanupStatus = await Task.detached(priority: .utility) { scope.moveToTrash(in: runtime) }.value
            } catch {
                cleanupStatus = "无法开始清理：" + error.localizedDescription
            }
            cleaning = false
            refresh()
        }
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

    private func invalidateSavedChecks() throws {
        // Model caches can be shared across runtimes. Invalidate their checks before moving files,
        // so a switch of runtime or an interrupted cleanup won't restore a stale "ready" status.
        let files = FileManager.default
        let entries: [String]
        do { entries = try files.contentsOfDirectory(atPath: cacheDirectory.path) }
        catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile { return }
        for key in entries where key.count == 64 && key.allSatisfy(\.isHexDigit) {
            let directory = cacheDirectory.appendingPathComponent(key)
            do {
                if try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory {
                    try files.removeItem(at: directory.appendingPathComponent("check.json"))
                }
            } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile { }
        }
    }

    func cancel() {
        guard active != nil else { return }
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

enum ModelCleanup: Sendable {
    case models, modelsAndEnvironment

    var title: String {
        switch self {
        case .models: "清理模型缓存"
        case .modelsAndEnvironment: "清理模型和运行环境"
        }
    }

    func moveToTrash(in runtime: URL) -> String {
        let plan = targets(in: runtime)
        var errors = plan.errors
        var moved = 0
        for url in plan.items {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
            } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if errors.isEmpty, moved == 0 { return "没有找到可清理的文件。" }
        return (["已将 \(moved) 项移到废纸篓。"] + errors).joined(separator: "\n")
    }

    func targets(in runtime: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                 variables: [String: String] = ProcessInfo.processInfo.environment) -> (items: [URL], errors: [String]) {
        let files = FileManager.default
        let runtime = runtime.resolvingSymlinksInPath()
        let home = home.resolvingSymlinksInPath()
        let userCache = home.appendingPathComponent(".cache")
        var items: [URL] = []
        var errors: [String] = []

        func configuredDirectory(_ keys: String...) -> URL? {
            guard let value = keys.compactMap({ variables[$0] }).first else { return nil }
            let path = (value as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        }

        func add(_ url: URL, type: FileAttributeType) {
            // A custom runtime can reference another installation via a symlink. Only move real entries
            // within the selected runtime or cache roots, without traversing nested symlinks.
            guard url.resolvingSymlinksInPath().path == url.path else { return }
            do {
                if try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == type {
                    items.append(url)
                }
            } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile { }
            catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }

        func addWeights(_ names: [String], in directory: URL, demucsTemporary: Bool = false) {
            guard directory.resolvingSymlinksInPath().path == directory.path else { return }
            do {
                for name in try files.contentsOfDirectory(atPath: directory.path) {
                    let partial = names.contains { asset in
                        (name.hasPrefix(".\(asset).") && (name.hasSuffix(".tmp") || name.hasSuffix(".part"))) ||
                        (name.hasPrefix("\(asset).") && name.hasSuffix(".partial"))
                    }
                    let converting = demucsTemporary && name.hasPrefix(".htdemucs.") &&
                        (name.hasSuffix(".safetensors") || name.hasSuffix(".json"))
                    if names.contains(name) || partial || converting {
                        add(directory.appendingPathComponent(name), type: .typeRegular)
                    }
                }
            } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile { }
            catch { errors.append("\(directory.lastPathComponent)：\(error.localizedDescription)") }
        }

        let cache = configuredDirectory("XDG_CACHE_HOME") ?? userCache
        let whisper = cache.appendingPathComponent("whisper")
        let whisperName = variables["MIT_WHISPER_MODEL"] ?? "base"
        let builtIn = ["tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
                       "large-v1", "large-v2", "large-v3", "large-v3-turbo"]
        let selected = ["large": "large-v3", "turbo": "large-v3-turbo"][whisperName] ?? whisperName
        if builtIn.contains(selected) {
            addWeights(selected == "base" ? ["base.pt"] : ["base.pt", "\(selected).pt"], in: whisper)
        } else if URL(fileURLWithPath: whisperName).resolvingSymlinksInPath().path != whisper.appendingPathComponent("base.pt").path {
            addWeights(["base.pt"], in: whisper)
        }

        let harmonix = (0..<8).flatMap { ["harmonix-fold\($0)_mlx.npz", "harmonix-fold\($0)_mlx.yaml"] }
        addWeights(harmonix, in: userCache.appendingPathComponent("all-in-one-mlx/weights"))
        let demucs = ["htdemucs.safetensors", "htdemucs_config.json", "htdemucs_mlx.pkl"]
        for folder in ["demucs-mlx", "mlx-weights/demucs-mlx"] {
            addWeights(demucs, in: userCache.appendingPathComponent(folder), demucsTemporary: true)
        }
        let torch = configuredDirectory("TORCH_HOME") ?? cache.appendingPathComponent("torch")
        addWeights(["955717e8-8726e21a.th", "wav2vec2_fairseq_base_ls960_asr_ls960.pth"],
                   in: torch.appendingPathComponent("hub/checkpoints"))

        let hfHome = configuredDirectory("HF_HOME") ?? cache.appendingPathComponent("huggingface")
        let hub = configuredDirectory("HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE") ?? hfHome.appendingPathComponent("hub")
        let transformers = configuredDirectory("TRANSFORMERS_CACHE", "PYTORCH_TRANSFORMERS_CACHE", "PYTORCH_PRETRAINED_BERT_CACHE") ?? hub
        for folder in Set([hub, transformers]) {
            for repo in ["models--jonatasgrosman--wav2vec2-large-xlsr-53-chinese-zh-cn", "models--m-a-p--MERT-v1-95M"] {
                add(folder.appendingPathComponent(repo), type: .typeDirectory)
            }
        }

        let emotion = runtime.appendingPathComponent(".models/Music2Emotion")
        if self == .modelsAndEnvironment, files.fileExists(atPath: emotion.appendingPathComponent("music2emo.py").path) {
            add(emotion, type: .typeDirectory)
        } else {
            addWeights(["J_all.ckpt"], in: emotion.appendingPathComponent("saved_models"))
            addWeights(["btc_model_large_voca.pt"], in: emotion.appendingPathComponent("inference/data"))
        }
        if self == .modelsAndEnvironment {
            for name in Set(ModelFeature.allCases.map(\.environment)) {
                let venv = runtime.appendingPathComponent(name)
                if files.fileExists(atPath: venv.appendingPathComponent("pyvenv.cfg").path) {
                    add(venv, type: .typeDirectory)
                }
            }
        }
        return (items, errors)
    }
}
