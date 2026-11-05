import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
import Observation

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Runtime {
    static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["MIT_RUNTIME"] ?? UserDefaults.standard.string(forKey: "runtime") {
            return URL(fileURLWithPath: path)
        }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: source.appendingPathComponent(".venv/bin/python").path) { return source }
        #endif
        return URL.applicationSupportDirectory.appendingPathComponent("MusicIntelligenceTool/Runtime")
    }
    static func process(_ script: String, args: [String], python: String = ".venv/bin/python", root: URL = Runtime.root) throws -> Process {
        guard let file = Bundle.main.url(forResource: script, withExtension: "py") else {
            throw StudioError.message("应用缺少脚本 \(script)")
        }
        let executable = root.appendingPathComponent(python)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw StudioError.message("Python 环境尚未安装，请运行 script/setup.sh，或选择已有运行环境。")
        }
        let p = Process()
        p.executableURL = executable
        p.arguments = [file.path] + args
        p.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": executable.deletingLastPathComponent().path + ":" + toolPath,
            "PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "TOKENIZERS_PARALLELISM": "false"
        ]) { _, new in new }
        return p
    }
}

@MainActor @Observable
final class Studio {
    let modelEnvironment: ModelEnvironment
    let root: URL
    var song: SongRecord?
    var selected: String?
    private(set) var inPoint: Double?
    private(set) var outPoint: Double?
    var selection: ClosedRange<Double>? {
        get {
            guard let inPoint, let outPoint else { return nil }
            return inPoint...outPoint
        }
        set {
            inPoint = newValue?.lowerBound
            outPoint = newValue?.upperBound
        }
    }
    var peaks: [Float] = []
    var zoom = 1.0
    var snap = true
    var loop = false
    var cursor = 0.0
    var playing = false
    var stem = "原曲"
    var visibleKinds: Set<String> = ["section", "note"]
    var notice: String?
    var serviceStatus = "未启动"
    static let defaultMCPPort = 18765
    /// MIT_MCP_PORT (used by tests) overrides the port chosen in Settings.
    static let portOverride = ProcessInfo.processInfo.environment["MIT_MCP_PORT"].flatMap { Int($0) }
    private(set) var mcpPort = portOverride ?? (UserDefaults.standard.object(forKey: "mcpPort") as? Int) ?? defaultMCPPort
    var mcpEndpoint: String { "http://127.0.0.1:\(mcpPort)/mcp" }
    var activeJob: AnalysisJob?
    var cueJobs: [AnalysisJob] = []
    private var player: AVAudioPlayer?
    private var worker: Process?
    private var service: Process?
    private var serviceReader: FileHandle?
    private var serviceInput: FileHandle?
    private var history: [(prior: [Mark], affected: Set<String>)] = []
    private var peakTask: Task<Void, Never>?

    init(root: URL? = nil) {
        let custom = ProcessInfo.processInfo.environment["MIT_LIBRARY"].map { URL(fileURLWithPath: $0) }
        self.root = root ?? custom ?? URL.applicationSupportDirectory.appendingPathComponent("MusicIntelligenceTool/Tracks")
        modelEnvironment = ModelEnvironment(cacheDirectory: self.root.appendingPathComponent(".environment"))
    }

    var row: Mark? { song?.marks.first { $0.id == selected } }
    var canUndo: Bool { !history.isEmpty }
    var position: Double { playing ? player?.currentTime ?? cursor : cursor }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["wav", "mp3", "flac", "m4a"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            do { try open(url) } catch { notice = error.localizedDescription }
        }
    }

    func open(_ url: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        if song?.path == path.path { return }
        guard activeJob == nil else { throw StudioError.message("请等待当前分析或取消后切换歌曲。") }
        let audio = try AVAudioPlayer(contentsOf: path)
        guard audio.duration > 0 else { throw StudioError.message("文件没有可播放的音频。") }
        var record = SongRecord(url: path, duration: audio.duration)
        let dir = root.appendingPathComponent(record.trackID)
        let file = dir.appendingPathComponent("analysis.json")
        if FileManager.default.fileExists(atPath: file.path) {
            record = try JSONDecoder().decode(SongRecord.self, from: Data(contentsOf: file))
            for (key, state) in record.status where state == "分析中" { record.status[key] = "已中断" }
        } else if path == Bundle.main.url(forResource: "Study", withExtension: "wav"),
                  let example = Bundle.main.url(forResource: "Study", withExtension: "json") {
            record.marks = try JSONDecoder().decode(SongRecord.self, from: Data(contentsOf: example)).marks
        }
        try record.save(in: root)
        player?.stop()
        player = audio
        song = record
        selected = record.sections.first?.id
        playing = false
        stem = "原曲"
        cursor = 0
        zoom = 1
        selection = nil
        history = []
        peaks = []
        peakTask?.cancel()
        peakTask = Task {
            do {
                let bins = try await Task.detached(priority: .userInitiated) { try Self.waveform(path) }.value
                if !Task.isCancelled { peaks = bins }
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }

    func openStudy() {
        guard let url = Bundle.main.url(forResource: "Study", withExtension: "wav") else { return }
        do { try open(url) } catch { notice = error.localizedDescription }
    }

    nonisolated static func waveform(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = max(1, min(24000, Int(file.length)))
        var bins = [Float](repeating: 0, count: count)
        let size = AVAudioFrameCount(16384)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: size) else { return bins }
        var index: Int64 = 0
        while index < file.length {
            try file.read(into: buffer, frameCount: size)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for i in 0..<Int(buffer.frameLength) {
                let bin = min(count-1, Int((index+Int64(i))*Int64(count)/file.length))
                for ch in 0..<Int(buffer.format.channelCount) { bins[bin] = max(bins[bin], abs(channels[ch][i])) }
            }
            index += Int64(buffer.frameLength)
        }
        return bins
    }

    func seek(_ t: Double) {
        cursor = max(0, min(song?.duration ?? 0, t))
        player?.currentTime = cursor
    }
    func markPoint(_ edge: CueEdge) {
        guard song != nil else { return }
        let time = position
        if edge == .entry {
            // An explicit in-point starts a fresh pair, even inside the previous selection.
            outPoint = nil
        } else if let outPoint, time > outPoint {
            inPoint = outPoint
        } else if inPoint == nil || time < (inPoint ?? 0) {
            // Start at zero for the first out-point, or when marking before the current in-point.
            inPoint = 0
        }
        setPoint(edge, at: time)
    }
    func setPoint(_ edge: CueEdge, at time: Double) {
        guard let song else { return }
        let t = min(song.duration, max(0, time))
        // Handle edits preserve the opposite endpoint unless it would invert the range.
        switch edge {
        case .entry:
            if let outPoint, t > outPoint { self.outPoint = nil }
            inPoint = t
        case .exit:
            if let inPoint, t < inPoint { self.inPoint = nil }
            outPoint = t
        }
    }
    func togglePlayback() {
        guard let player else { return }
        if playing { cursor = player.currentTime; player.pause(); playing = false }
        else {
            if loop, let range = loopRange, !range.contains(cursor) { seek(range.lowerBound) }
            if cursor >= player.duration { seek(0) }
            playing = player.play()
        }
    }
    var loopRange: ClosedRange<Double>? { selection ?? row.map { $0.start...$0.end } }
    func tick() {
        guard playing, let player else { return }
        if loop, let r = loopRange, r.upperBound > r.lowerBound,
           !player.isPlaying || player.currentTime >= r.upperBound { seek(r.lowerBound); player.play() }
        else if !player.isPlaying { playing = false; seek(0) }
        else { cursor = player.currentTime }
    }
    func chooseStem(_ name: String) {
        guard let song, let path = name == "原曲" ? song.path : song.stems[name] else { return }
        do {
            let next = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            next.currentTime = position
            player?.stop()
            player = next
            stem = name
            if playing { playing = next.play() }
        } catch { notice = error.localizedDescription }
    }

    func edit(_ change: (inout SongRecord) -> Void) {
        guard var current = song else { return }
        let old = current.marks
        change(&current)
        guard old != current.marks else { return }
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let updated = Dictionary(uniqueKeysWithValues: current.marks.map { ($0.id, $0) })
        let changed = Set(previous.keys).union(updated.keys).filter { previous[$0] != updated[$0] }
        if old.filter({ $0.kind == "section" }).map(\.end) != current.sections.map(\.end),
           current.status["emotion"] != nil { current.status["emotion"] = "待更新" }
        do {
            try current.save(in: root)
            history.append((old.filter { changed.contains($0.id) }, Set(changed)))
            song = current
        } catch { notice = error.localizedDescription }
    }
    func undo() {
        guard let entry = history.last, var current = song else { return }
        current.marks.removeAll { entry.affected.contains($0.id) }
        current.marks += entry.prior
        do {
            try current.save(in: root)
            history.removeLast()
            song = current
            if row == nil { selected = current.sections.first?.id }
        } catch { notice = error.localizedDescription }
    }
    func select(_ mark: Mark) { selected = mark.id; seek(mark.start) }

    func deleteSection(_ id: String) {
        var neighbour: String?
        edit { neighbour = $0.deleteSection(id) }
        if selected == id, row == nil { selected = neighbour }
    }

    func add(_ kind: String) {
        let a = inPoint ?? outPoint ?? position
        let b = outPoint ?? a
        if kind == "section" {
            edit { doc in
                for t in [a, b] {
                    if let part = doc.sections.first(where: { $0.start < t && t < $0.end }) { doc.split(part.id, at: t) }
                }
            }
            selected = song?.sections.first(where: { $0.start == a })?.id
        } else {
            let row = Mark.manual(kind, from: a, to: b, label: kind == "lyric" ? "" : "新注释")
            edit { $0.marks.append(row) }
            selected = row.id
            visibleKinds.insert(kind)
        }
    }
    func exportJSON() {
        guard let song else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = URL(fileURLWithPath: song.path).deletingPathExtension().lastPathComponent + ".analysis.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(song).write(to: url, options: .atomic)
        } catch { notice = error.localizedDescription }
    }

    func run(_ jobs: [AnalysisJob], range: ClosedRange<Double>? = nil) {
        guard activeJob == nil, let song else { return }
        cueJobs = jobs
        let interval = range ?? 0...song.duration
        launchNext(interval)
    }

    private func launchNext(_ interval: ClosedRange<Double>) {
        guard !cueJobs.isEmpty, var doc = song else { activeJob = nil; return }
        let job = cueJobs.removeFirst()
        activeJob = job
        let dir = root.appendingPathComponent(doc.trackID)
        let runID = UUID().uuidString
        let out = dir.appendingPathComponent(runID+".json")
        let log = dir.appendingPathComponent(job.rawValue+".log")
        let bounds = job == .structure ? 0...doc.duration : interval
        let sourceSections = doc.sections.map { [$0.start, $0.end] }
        let sourceLyrics = doc.marks.filter { $0.kind == "lyric" }
        do {
            guard bounds.upperBound > bounds.lowerBound else { throw StudioError.message("请选择有时长的区间。") }
            let python = job == .emotion ? ".venv-emotion/bin/python" : job == .alignment ? ".venv-align/bin/python" : ".venv/bin/python"
            let p = try Runtime.process("analysis_worker", args: [job.rawValue, dir.appendingPathComponent("analysis.json").path,
                out.path, Runtime.root.path, String(bounds.lowerBound), String(bounds.upperBound)], python: python)
            try Data().write(to: log)
            let output = try FileHandle(forWritingTo: log)
            p.standardOutput = output
            p.standardError = output
            p.currentDirectoryURL = dir
            p.terminationHandler = { [weak self] proc in
                try? output.close()
                Task { @MainActor [weak self] in
                    guard let self, self.worker === proc, var current = self.song else { return }
                    self.worker = nil
                    defer { try? FileManager.default.removeItem(at: out); self.launchNext(interval) }
                    do {
                        if proc.terminationStatus != 0 {
                            let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n")
                            throw StudioError.message(String(lines?.last?.suffix(240) ?? "进程退出"))
                        }
                        let result = try JSONDecoder().decode(JobResult.self, from: Data(contentsOf: out))
                        if job == .alignment && sourceLyrics != current.marks.filter({ $0.kind == "lyric" }) {
                            current.status[job.rawValue] = "待更新"
                        } else {
                            current.apply(result, job: job, range: bounds.lowerBound..<bounds.upperBound)
                            if job == .emotion && sourceSections != current.sections.map({ [$0.start, $0.end] }) {
                                current.status[job.rawValue] = "待更新"
                            }
                        }
                    } catch { current.status[job.rawValue] = "失败 · " + error.localizedDescription }
                    self.persist(current)
                }
            }
            doc.status[job.rawValue] = "分析中"
            try doc.save(in: root)
            song = doc
            worker = p
            try p.run()
        } catch {
            worker = nil
            doc.status[job.rawValue] = "失败 · " + error.localizedDescription
            persist(doc)
            launchNext(interval)
        }
    }
    private func persist(_ doc: SongRecord) {
        var updated = doc
        do { try updated.save(in: root); song = updated } catch { notice = error.localizedDescription }
    }
    func cancel() {
        cueJobs = []
        let process = worker
        worker = nil
        if process?.isRunning == true { process?.terminate() }
        if var current = song, let job = activeJob { current.status[job.rawValue] = "已取消"; persist(current) }
        activeJob = nil
    }

    func startMCP() {
        guard service == nil else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let p = try Runtime.process("music_mcp", args: [root.path])
            let port = mcpPort
            p.environment?["MIT_MCP_PORT"] = String(port)
            let requests = Pipe(), replies = Pipe()
            p.standardOutput = requests
            p.standardInput = replies
            let log = mcpLog
            try Data().write(to: log)
            let errors = try FileHandle(forWritingTo: log)
            p.standardError = errors
            serviceInput = replies.fileHandleForWriting
            let reader = requests.fileHandleForReading
            serviceReader = reader
            p.terminationHandler = { [weak self] process in
                try? errors.close()
                Task { @MainActor [weak self] in
                    guard let self, self.service === process else { return }
                    self.service = nil
                    let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
                    // uvicorn logs the bind failure first, then a generic shutdown line.
                    self.serviceStatus = lines.contains { $0.contains("address already in use") }
                        ? "端口 \(port) 已被其他程序占用，请在设置中更换端口。"
                        : "服务已停止 · " + (lines.last { $0.contains("ERROR") } ?? lines.last ?? "")
                }
            }
            try p.run()
            service = p
            serviceStatus = mcpEndpoint
            Task.detached { [weak self] in
                do {
                    for try await line in reader.bytes.lines { await self?.receive(line) }
                } catch { /* Closing the service pipe ends the request stream. */ }
            }
        } catch { serviceStatus = error.localizedDescription }
    }

    private func receive(_ line: String) {
        let response: [String: String]
        do {
            guard !modelEnvironment.downloading else { throw StudioError.message("模型正在下载，请稍后再发起分析。") }
            let request = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
            guard let path = request["path"] else { throw StudioError.message("缺少音频路径") }
            try open(URL(fileURLWithPath: path))
            guard let doc = song else { throw StudioError.message("歌曲未打开") }
            let pending = Self.defaultJobs.filter { !["完成", "无可靠结果"].contains(doc.status[$0.rawValue]) }
            if !pending.isEmpty { run(pending) }
            response = ["track_id": doc.trackID, "status": activeJob == nil ? "ready" : "running"]
        } catch { response = ["error": error.localizedDescription] }
        if let data = try? JSONEncoder().encode(response) {
            try? serviceInput?.write(contentsOf: data + Data([10]))
        }
    }
    static let defaultJobs: [AnalysisJob] = [.acoustics, .harmony, .structure, .lyrics, .emotion]
    func chooseRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "runtime")
        modelEnvironment.checkIfNeeded(in: Runtime.root)
        restartMCP()
    }
    var mcpRunning: Bool { service != nil }
    func setMCPPort(_ port: Int) {
        guard Self.portOverride == nil, port != mcpPort else { return }
        UserDefaults.standard.set(port, forKey: "mcpPort")
        mcpPort = port
        restartMCP()
    }
    var mcpLog: URL { root.appendingPathComponent("mcp.log") }
    func restartMCP() {
        let previous = service
        stopService()
        Task {
            // The old server must release the port before the new one can bind it.
            for _ in 0..<60 where previous?.isRunning == true { try? await Task.sleep(for: .milliseconds(50)) }
            startMCP()
        }
    }
    private func stopService() {
        let p = service
        service = nil
        try? serviceInput?.close()
        if p?.isRunning == true { p?.terminate() }
    }
    func stop() { cancel(); stopService(); modelEnvironment.cancel(); player?.stop() }
}
