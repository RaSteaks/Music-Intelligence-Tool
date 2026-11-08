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

/// A track the user opened, kept per library so the record shelf can render it from its saved analysis.
struct RecentTrack: Codable, Equatable, Identifiable {
    var trackID: String
    var path: String
    var openedAt: Date
    var id: String { trackID }
    var title: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

@MainActor @Observable
final class Studio {
    static let audioContentTypes = ["wav", "mp3", "flac", "m4a"].compactMap { UTType(filenameExtension: $0) }
    let modelEnvironment: ModelEnvironment
    let externalModels: ExternalModels
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
    /// Event sub-lanes ("event:vocals" …) hidden one at a time while the event track itself stays on.
    var hiddenLanes: Set<String> = []
    /// First data lane shown when more lanes are on than the canvas can fit.
    var laneScroll = 0
    var notice: String?
    var serviceStatus = "未启动"
    private var agentSendID: UUID?
    var sendingToAgent: Bool { agentSendID != nil }
    private(set) var agentSendStatus: String?
    static var channelEndpoint: URL {
        let port = ProcessInfo.processInfo.environment["MIT_CHANNEL_PORT"].flatMap(Int.init) ?? 18766
        return URL(string: "http://127.0.0.1:\(port)/handoff")!
    }
    static let defaultMCPPort = 18765
    /// MIT_MCP_PORT (used by tests) overrides the port chosen in Settings.
    static let portOverride = ProcessInfo.processInfo.environment["MIT_MCP_PORT"].flatMap { Int($0) }
    private(set) var mcpPort = portOverride ?? (UserDefaults.standard.object(forKey: "mcpPort") as? Int) ?? defaultMCPPort
    var mcpEndpoint: String { "http://127.0.0.1:\(mcpPort)/mcp" }
    var activeJob: AnalysisJob?
    var cueJobs: [AnalysisJob] = []
    private var skipCompletedJobs = false
    private var player: AVAudioPlayer?
    private var worker: Process?
    private var service: Process?
    private var serviceReader: FileHandle?
    private var serviceInput: FileHandle?
    private var history: [(prior: [Mark], affected: Set<String>)] = []
    private var peakTask: Task<Void, Never>?
    private var cloudTask: Task<Void, Never>?
    var cloudProgress: String?
    private(set) var completedComparisonID: String?
    var cloudRunning: Bool { cloudTask != nil }
    private(set) var recents: [RecentTrack] = []
    private var recentsFile: URL { root.appendingPathComponent("recents.json") }

    init(root: URL? = nil, credentials: CloudCredentialStore = KeychainCredentials()) {
        let custom = ProcessInfo.processInfo.environment["MIT_LIBRARY"].map { URL(fileURLWithPath: $0) }
        self.root = root ?? custom ?? URL.applicationSupportDirectory.appendingPathComponent("MusicIntelligenceTool/Tracks")
        modelEnvironment = ModelEnvironment(cacheDirectory: self.root.appendingPathComponent(".environment"))
        externalModels = ExternalModels(directory: self.root.appendingPathComponent(".external-models"), credentials: credentials)
        recents = (try? JSONDecoder().decode([RecentTrack].self, from: Data(contentsOf: recentsFile))) ?? []
    }

    var row: Mark? { song?.marks.first { $0.id == selected } }
    var canUndo: Bool { !history.isEmpty }
    var position: Double { playing ? player?.currentTime ?? cursor : cursor }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioContentTypes
        if panel.runModal() == .OK, let url = panel.url {
            do { try open(url) } catch { notice = error.localizedDescription }
        }
    }

    func openDroppedAudio(_ urls: [URL]) -> Bool {
        guard urls.count == 1 else {
            notice = "请一次拖入一个音频文件。"
            return false
        }
        let url = urls[0]
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              Self.audioContentTypes.contains(where: { type.conforms(to: $0) }) else {
            notice = "请拖入本地音频文件，支持 WAV、MP3、FLAC 或 M4A。"
            return false
        }
        do {
            // Use the same import path so drops preserve saved edits and respect active analysis jobs.
            try open(url)
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    func open(_ url: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath()
        if song?.path == path.path { return }
        guard activeJob == nil, !cloudRunning else { throw StudioError.message("请等待当前分析或取消后切换歌曲。") }
        let audio = try AVAudioPlayer(contentsOf: path)
        guard audio.duration > 0 else { throw StudioError.message("文件没有可播放的音频。") }
        var record = SongRecord(url: path, duration: audio.duration)
        let dir = root.appendingPathComponent(record.trackID)
        let file = dir.appendingPathComponent("analysis.json")
        var needsSave = true
        if FileManager.default.fileExists(atPath: file.path) {
            record = try JSONDecoder().decode(SongRecord.self, from: Data(contentsOf: file))
            let previousStatus = record.status
            let previousCloudStatus = record.cloudRuns?.map(\.status)
            let previousBatchStatus = record.cloudBatches?.map(\.status)
            let previousMarks = record.marks
            for (key, state) in record.status where state == "分析中" { record.status[key] = "已中断" }
            for index in record.cloudRuns?.indices ?? 0..<0 {
                if ["准备中", "分析中"].contains(record.cloudRuns?[index].status ?? "") {
                    record.cloudRuns?[index].status = "已中断"
                    record.cloudRuns?[index].message = "应用退出前的请求未确认完成；如已提交，可能仍产生费用。"
                }
            }
            for index in record.cloudBatches?.indices ?? 0..<0 where record.cloudBatches?[index].status == "分析中" {
                record.cloudBatches?[index].status = "已中断"
                record.cloudBatches?[index].message = "批次已中断；已完成片段保留，重新运行可复用有效缓存。"
            }
            record.reconcileCloudResults()
            needsSave = record.status != previousStatus || record.cloudRuns?.map(\.status) != previousCloudStatus || record.cloudBatches?.map(\.status) != previousBatchStatus || record.marks != previousMarks
        } else if path == Bundle.main.url(forResource: "Study", withExtension: "wav")?.standardizedFileURL.resolvingSymlinksInPath(),
                  let example = Bundle.main.url(forResource: "Study", withExtension: "json") {
            record.marks = try JSONDecoder().decode(SongRecord.self, from: Data(contentsOf: example)).marks
        }
        // Opening a saved record is read-only unless interrupted/stale analysis
        // needs recovery. A new revision otherwise misrepresents a user edit.
        if needsSave { try record.save(in: root) }
        player?.stop()
        player = audio
        song = record
        remember(record)
        // Invalidate old receipts even when switching away and back to the same track.
        // The agent can still read the previous snapshot, but it no longer owns this workspace's status.
        agentSendID = nil
        agentSendStatus = nil
        completedComparisonID = nil
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

    private func remember(_ record: SongRecord) {
        recents.removeAll { $0.trackID == record.trackID }
        recents.insert(RecentTrack(trackID: record.trackID, path: record.path, openedAt: Date()), at: 0)
        recents = Array(recents.prefix(12))
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(recents).write(to: recentsFile, options: .atomic)
        } catch { /* The shelf is a convenience; failing to save it must not block opening a song. */ }
    }

    func openRecent(_ recent: RecentTrack) {
        guard FileManager.default.fileExists(atPath: recent.path) else {
            notice = "找不到原音频文件：" + recent.path
            return
        }
        do { try open(URL(fileURLWithPath: recent.path)) } catch { notice = error.localizedDescription }
    }

    /// Reads a saved record for the shelf without opening it.
    nonisolated static func savedRecord(in root: URL, trackID: String) -> SongRecord? {
        let file = root.appendingPathComponent(trackID).appendingPathComponent("analysis.json")
        return try? JSONDecoder().decode(SongRecord.self, from: Data(contentsOf: file))
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
        if old.filter({ $0.kind == "section" }).map(\.end) != current.sections.map(\.end) {
            current.invalidateAnalysis(.emotion)
            current.invalidateAnalysis(.repetition)
            current.invalidateAnalysis(.harmony, kinds: ["key_region", "modulation"])
        }
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
    /// Sends `snapshot` when given (the revision the handoff preview showed), otherwise the current song.
    func sendToAgent(_ snapshot: SongRecord? = nil) async {
        guard !sendingToAgent, let song = snapshot ?? self.song else { return }
        let endpoint = Self.channelEndpoint
        // Capture the clicked revision before awaiting: analysis and edits may continue during delivery.
        let sendID = UUID()
        agentSendID = sendID
        agentSendStatus = "正在发送完整分析记录…"
        defer {
            // An older request must not unlock the send button for a newer handoff.
            if agentSendID == sendID { agentSendID = nil }
        }
        struct Receipt: Decodable {
            var handoff_id: String
            var status: String
        }
        do {
            var request = URLRequest(url: endpoint, timeoutInterval: 3)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(song)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard agentSendID == sendID else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 202 else {
                throw StudioError.message("音乐接收服务未接受记录，请检查 Claude Code 的 Channel 配置后重试。")
            }
            let receipt = try JSONDecoder().decode(Receipt.self, from: data)
            agentSendStatus = "已通知 Claude Code，等待读取完整记录…"
            let statusURL = endpoint.appendingPathComponent(receipt.handoff_id)
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(500))
                guard agentSendID == sendID else { return }
                let (statusData, statusResponse) = try await URLSession.shared.data(for: URLRequest(url: statusURL, timeoutInterval: 3))
                guard agentSendID == sendID else { return }
                guard (statusResponse as? HTTPURLResponse)?.statusCode == 200 else {
                    throw StudioError.message("音乐接收服务已重启或交接记录已失效，请重新发送。")
                }
                let delivery = try JSONDecoder().decode(Receipt.self, from: statusData)
                if delivery.status == "read" {
                    agentSendStatus = "Claude Code 已读取完整记录（修订 \(song.revision)）"
                    return
                }
                if delivery.status == "reading" { agentSendStatus = "Claude Code 正在读取完整记录…" }
            }
            // Channels do not acknowledge notifications. A queued event must never look like confirmed delivery.
            agentSendStatus = "已通知 Claude Code，尚未确认读取；请检查 Channel 是否启用。"
        } catch {
            guard agentSendID == sendID else { return }
            agentSendStatus = "未确认发送，请检查 Claude Code 连接后重试。"
            notice = "无法确认 Claude Code 已读取记录。请先启动音乐接收服务，再重试。\n" + error.localizedDescription
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

    func run(_ jobs: [AnalysisJob], range: ClosedRange<Double>? = nil, skipCompleted: Bool = false) {
        guard activeJob == nil, let song else { return }
        skipCompletedJobs = skipCompleted
        cueJobs = jobs
        let interval = range ?? 0...song.duration
        launchNext(interval)
    }

    private func launchNext(_ interval: ClosedRange<Double>) {
        guard !cueJobs.isEmpty, var doc = song else { activeJob = nil; return }
        let job = cueJobs.removeFirst()
        let bounds = job.requiresWholeTrack ? 0...doc.duration : interval
        // MCP checks completion when a job reaches the front: a successful
        // upstream job may invalidate it, while a failed upstream job should
        // not force unrelated completed analyses to run again.
        if skipCompletedJobs && doc.hasCompleted(job, in: bounds) {
            launchNext(interval); return
        }
        activeJob = job
        let dir = root.appendingPathComponent(doc.trackID)
        let runID = UUID().uuidString
        let out = dir.appendingPathComponent(runID+".json")
        let log = dir.appendingPathComponent(job.rawValue+".log")
        let sourceSections = doc.sections.map { [$0.start, $0.end] }
        let sourceLyrics = doc.marks.filter { $0.kind == "lyric" }
        do {
            guard bounds.upperBound > bounds.lowerBound else { throw StudioError.message("请选择有时长的区间。") }
            let python: String
            switch job {
            case .emotion: python = ".venv-emotion/bin/python"
            case .alignment: python = ".venv-align/bin/python"
            case .melody: python = ".venv-music/bin/python"
            default: python = ".venv/bin/python"
            }
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
                            if [.emotion, .repetition, .harmony].contains(job) && sourceSections != current.sections.map({ [$0.start, $0.end] }) {
                                current.invalidateAnalysis(job)
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

    func startCloud(connectionID: String, task: CloudTaskKind, range: AnalysisRange, force: Bool = false,
                    options supplied: CloudTaskOptions? = nil) {
        guard !cloudRunning, let snapshot = song,
              let connection = externalModels.configuration.connections.first(where: { $0.id == connectionID }) else { return }
        let options = supplied ?? CloudTaskOptions(audioSources: task == .audio ? [.original] : [])
        do {
            try options.validate(task: task, range: range, duration: snapshot.duration)
            if !options.audioSources.isEmpty && !connection.audioAvailable {
                throw CloudError.configuration("此模型的音频能力未知，请先在外部模型设置中运行音频能力测试。")
            }
            let key = try externalModels.key(for: connection)
            cloudProgress = "准备分析输入…"
            cloudTask = Task {
                defer { cloudTask = nil; cloudProgress = nil }
                do { _ = try await performCloud(snapshot: snapshot, connection: connection, key: key, task: task,
                                                range: range, options: options, force: force) }
                catch { if !Task.isCancelled { notice = error.localizedDescription } }
            }
        } catch { notice = error.localizedDescription }
    }

    func startCloudBatch(connectionID: String, summaryConnectionID: String, plan: CloudBatchPlan, force: Bool = false) {
        guard !cloudRunning, let snapshot = song,
              let connection = externalModels.configuration.connections.first(where: { $0.id == connectionID }),
              let summaryConnection = externalModels.configuration.connections.first(where: { $0.id == summaryConnectionID }) else { return }
        do {
            try connection.validate(); try summaryConnection.validate()
            guard !plan.ranges.isEmpty, plan.requestCount <= plan.maximumRequests, (2...50).contains(plan.maximumRequests),
                  plan.ranges.first?.start == 0, plan.ranges.last?.end == snapshot.duration,
                  zip(plan.ranges, plan.ranges.dropFirst()).allSatisfy({ pair in pair.0.end == pair.1.start }) else {
                throw CloudError.configuration("整曲计划不完整或超过请求上限，请重新预览。")
            }
            for range in plan.ranges {
                try CloudTaskOptions(audioSources: plan.audioSources).validate(task: plan.audioSources.isEmpty ? .interpretation : .audio,
                                                                             range: range, duration: snapshot.duration)
            }
            if !plan.audioSources.isEmpty && !connection.audioAvailable { throw CloudError.configuration("分段模型的音频能力尚未验证。") }
            // Capture both credentials with the reviewed connection snapshots.
            // Editing a connection during a batch must not retarget later calls.
            let key = try externalModels.key(for: connection)
            let summaryKey = try externalModels.key(for: summaryConnection)
            let batch = CloudBatch(ranges: plan.ranges, audioSources: plan.audioSources, maximumRequests: plan.maximumRequests)
            try updateCloudRecord { record in
                if record.cloudBatches == nil { record.cloudBatches = [] }
                record.cloudBatches?.append(batch)
            }
            cloudProgress = "准备整曲分析…"
            cloudTask = Task {
                defer { cloudTask = nil; cloudProgress = nil }
                do {
                    var completedRuns: [String] = []
                    for (index, range) in plan.ranges.enumerated() {
                        try Task.checkCancellation()
                        let options = CloudTaskOptions(audioSources: plan.audioSources)
                        guard let current = song,
                              try current.cloudInputFingerprint(in: range, options: options) == snapshot.cloudInputFingerprint(in: range, options: options) else {
                            throw CloudError.configuration("待分析片段的输入已变化，已停止批次。已完成结果保留，请重新预览后运行。")
                        }
                        let id = try await performCloud(snapshot: snapshot, connection: connection, key: key,
                                                        task: plan.audioSources.isEmpty ? .interpretation : .audio,
                                                        range: range, options: options, force: force, batchID: batch.id,
                                                        progressPrefix: "片段 \(index + 1)/\(plan.ranges.count) · ")
                        completedRuns.append(id)
                        guard song?.hasCurrentCloudRuns(completedRuns) == true else {
                            throw CloudError.configuration("分析期间输入发生变化，已保留候选并停止后续请求。")
                        }
                    }
                    guard let current = song else { throw CloudError.configuration("歌曲已关闭。") }
                    let range = AnalysisRange(start: 0, end: current.duration)
                    let completed = Set(completedRuns)
                    let ids = current.marks.filter { row in
                        guard let origin = row.fields["label"]?.origin else { return false }
                        return completed.contains(origin.runID) && origin.stale == false
                    }.map(\.id).sorted()
                    let options = CloudTaskOptions(inputInsightIDs: ids, compactContext: true,
                                                   missingRanges: current.unanalyzedRanges(in: range, runIDs: completed))
                    let id = try await performCloud(snapshot: current, connection: summaryConnection, key: summaryKey,
                                                    task: .overview, range: range, options: options, force: force,
                                                    batchID: batch.id, progressPrefix: "整曲汇总 · ")
                    try updateCloudRecord { record in
                        if let index = record.cloudBatches?.firstIndex(where: { $0.id == batch.id }) {
                            record.cloudBatches?[index].summaryRunID = id
                            record.cloudBatches?[index].status = record.cloudRuns?.first(where: { $0.id == id })?.status == "待更新" ? "待更新" : "完成"
                        }
                    }
                } catch {
                    do {
                        try updateCloudRecord { record in
                            if let index = record.cloudBatches?.firstIndex(where: { $0.id == batch.id }) {
                                let ids = Set(record.cloudBatches?[index].runIDs ?? [])
                                let success = record.cloudRuns?.contains { ids.contains($0.id) && ["完成", "无可靠结果"].contains($0.status) } == true
                                record.cloudBatches?[index].status = Task.isCancelled ? "已取消" : success ? "部分完成" : "失败"
                                record.cloudBatches?[index].message = "已停止后续请求，保留已完成片段；重新运行可复用有效缓存。" + error.localizedDescription
                            }
                        }
                    } catch { notice = "批次状态保存失败：" + error.localizedDescription; return }
                    if !Task.isCancelled { notice = error.localizedDescription }
                }
            }
        } catch { notice = error.localizedDescription }
    }

    func compareModels(connectionIDs: [String], task: CloudTaskKind, range: AnalysisRange, options: CloudTaskOptions, force: Bool = false) {
        guard !cloudRunning, let snapshot = song else { return }
        do {
            try options.validate(task: task, range: range, duration: snapshot.duration)
            let connections = connectionIDs.compactMap { id in externalModels.configuration.connections.first { $0.id == id } }
            guard connections.count == 2, connections[0].validationSignature != connections[1].validationSignature else {
                throw CloudError.configuration("请选择两个不同模型或渠道的连接。")
            }
            for connection in connections {
                try connection.validate()
                if !options.audioSources.isEmpty && !connection.audioAvailable { throw CloudError.configuration("两个连接都需要支持所选音频输入。") }
                if range.duration * Double(options.audioSources.count) > connection.maxAudioSeconds { throw CloudError.configuration("音频合计时长超过其中一个连接的限制。") }
            }
            let keys = try connections.map { try externalModels.key(for: $0) }
            let fingerprint = try snapshot.cloudInputFingerprint(in: range, options: options)
            var batch = CloudBatch(ranges: [range, range], audioSources: options.audioSources, maximumRequests: 2)
            batch.mode = "models"
            try updateCloudRecord { record in
                if record.cloudBatches == nil { record.cloudBatches = [] }
                record.cloudBatches?.append(batch)
            }
            cloudProgress = "准备同一输入的双模型对照…"
            cloudTask = Task {
                defer { cloudTask = nil; cloudProgress = nil }
                var successes = 0
                var failures: [String] = []
                for index in connections.indices {
                    if Task.isCancelled { break }
                    do {
                        guard let current = song, try current.cloudInputFingerprint(in: range, options: options) == fingerprint else {
                            throw CloudError.configuration("输入已变化，当前对照需要重新运行。")
                        }
                        _ = try await performCloud(snapshot: snapshot, connection: connections[index], key: keys[index], task: task,
                                                   range: range, options: options, force: force, batchID: batch.id,
                                                   progressPrefix: "模型 \(index+1)/2 · ")
                        successes += 1
                    } catch { failures.append(connections[index].name + "：" + error.localizedDescription) }
                }
                do {
                    try updateCloudRecord { record in
                        if let index = record.cloudBatches?.firstIndex(where: { $0.id == batch.id }) {
                            let ids = Set(record.cloudBatches?[index].runIDs ?? [])
                            let stale = record.cloudRuns?.contains { ids.contains($0.id) && $0.status == "待更新" } == true
                            record.cloudBatches?[index].status = Task.isCancelled ? "已取消" : stale ? "待更新" : successes == 2 ? "完成" : successes == 1 ? "部分完成" : "失败"
                            record.cloudBatches?[index].message = failures.isEmpty ? "同一输入独立分析；未调用第三个模型裁判，也不将多数意见视为事实。" : failures.joined(separator: "\n")
                        }
                    }
                    completedComparisonID = batch.id
                } catch { notice = error.localizedDescription }
            }
        } catch { notice = error.localizedDescription }
    }

    private func performCloud(snapshot: SongRecord, connection: ModelConnection, key: String, task: CloudTaskKind,
                              range: AnalysisRange, options: CloudTaskOptions, force: Bool,
                              batchID: String? = nil, progressPrefix: String = "") async throws -> String {
        var runID: String?
        var submitted = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MIT-cloud-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try Task.checkCancellation()
            let context = snapshot.cloudContext(in: range, options: options)
            let fingerprint = try snapshot.cloudInputFingerprint(in: range, options: options)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var run = CloudRun(task: task, provider: connection.provider.rawValue, model: connection.model,
                               range: range, inputRevision: snapshot.revision, inputFingerprint: fingerprint)
            run.context = context; run.options = options; run.batchID = batchID
            run.promptVersion = "music-insights-v2"
            run.endpointHost = try connection.endpoint(connection.apiStyle.path).host
            runID = run.id
            try updateCloudRecord { record in
                if record.cloudRuns == nil { record.cloudRuns = [] }
                record.cloudRuns?.append(run)
                if let batchID, let index = record.cloudBatches?.firstIndex(where: { $0.id == batchID }) {
                    record.cloudBatches?[index].runIDs.append(run.id)
                }
            }
            guard range.duration * Double(options.audioSources.count) <= connection.maxAudioSeconds else {
                throw CloudError.configuration("所选音轨合计时长超过此连接上限，请缩小选区或减少音轨。")
            }
            var attachments: [CloudAudioAttachment] = []
            for reference in context.audioReferences ?? [] {
                cloudProgress = progressPrefix + "裁切" + reference.source.title + "…"
                let path: String
                if reference.source == .original { path = snapshot.path }
                else if let stem = snapshot.stems[reference.source.rawValue] { path = stem }
                else { throw CloudError.configuration("缺少\(reference.source.title)，请先运行分轨分析。") }
                let audio = try await CloudAudio.prepare(source: URL(fileURLWithPath: path), range: range, directory: directory)
                attachments.append(CloudAudioAttachment(reference: reference, data: audio))
            }
            try Task.checkCancellation()
            if let batchID, let current = song, let batch = current.cloudBatches?.first(where: { $0.id == batchID }), batch.mode != "models" {
                // Cutting audio can suspend the task while the user edits a
                // previously completed segment. Check again before sending.
                guard current.hasCurrentCloudRuns(batch.runIDs.filter { $0 != run.id }),
                      try current.cloudInputFingerprint(in: range, options: options) == fingerprint else {
                    throw CloudError.configuration("批次输入已变化，已停止后续请求。")
                }
            }
            if !attachments.isEmpty {
                run.audioFingerprint = SongRecord.digest(Data(attachments.map { $0.reference.id + ":" + SongRecord.digest($0.data) }.joined(separator: "|").utf8))
            }
            let cacheKey = [connection.validationSignature, String(connection.maxOutputTokens), task.rawValue,
                            fingerprint, run.audioFingerprint ?? "", run.promptVersion].joined(separator: "|")
            run.requestFingerprint = SongRecord.digest(Data(cacheKey.utf8))
            if !force, let cached = song?.cloudRuns?.last(where: {
                $0.id != run.id && $0.requestFingerprint == run.requestFingerprint && $0.hasCurrentResult
            }) {
                try updateCloudRecord { record in
                    record.cloudRuns?.removeAll { $0.id == run.id }
                    if let batchID, let index = record.cloudBatches?.firstIndex(where: { $0.id == batchID }) {
                        record.cloudBatches?[index].runIDs.removeAll { $0 == run.id }
                        record.cloudBatches?[index].runIDs.append(cached.id)
                    }
                }
                selected = song?.marks.first { $0.fields["label"]?.origin?.runID == cached.id }?.id
                if batchID == nil { notice = "已复用相同输入的有效分析；未再次发送请求。需要新的结果时启用“重新调用模型”。" }
                return cached.id
            }
            cloudProgress = progressPrefix + (attachments.isEmpty ? "正在解读分析结果…" : "正在上传并分析音频…")
            let client = CloudClient()
            let request = try client.makeRequest(connection: connection, key: key, context: context, task: task, attachments: attachments)
            run.status = "分析中"
            try updateCloudRecord { record in
                if let batchID, let index = record.cloudBatches?.firstIndex(where: { $0.id == batchID }), var batch = record.cloudBatches?[index] {
                    guard batch.submittedRequests < batch.maximumRequests else {
                        throw CloudError.configuration("本批次已达到请求上限。")
                    }
                    batch.submittedRequests += 1
                    record.cloudBatches?[index] = batch
                }
                if let index = record.cloudRuns?.firstIndex(where: { $0.id == run.id }) { record.cloudRuns?[index] = run }
            }
            submitted = true
            let response = try await client.complete(request, style: connection.apiStyle, context: context, task: task)
            try Task.checkCancellation()
            cloudProgress = progressPrefix + "校验并保存建议…"
            try updateCloudRecord { record in
                if let index = record.cloudRuns?.firstIndex(where: { $0.id == run.id }) {
                    record.cloudRuns?[index].actualModel = response.model
                    record.cloudRuns?[index].upstreamProvider = response.provider
                    record.cloudRuns?[index].usage = response.usage
                }
                try record.applyCloud(response.answer, runID: run.id)
            }
            selected = song?.marks.first { $0.fields["label"]?.origin?.runID == run.id }?.id ?? selected
            visibleKinds.insert("insight")
            return run.id
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let message = cancelled ? "已取消。已经提交的远端请求可能仍产生费用。" : error.localizedDescription
            if let runID {
                try updateCloudRecord { record in
                    if let index = record.cloudRuns?.firstIndex(where: { $0.id == runID }) {
                        let uncertain = submitted && (error as? CloudError)?.requestMayStillBeRunning == true
                        record.cloudRuns?[index].status = cancelled ? "已取消" : uncertain ? "结果未确认" : "失败"
                        record.cloudRuns?[index].message = message
                        record.cloudRuns?[index].finishedAt = Date()
                        if let failure = error as? CloudError,
                           case .rejectedResponse(_, let model, let provider, let usage) = failure {
                            record.cloudRuns?[index].actualModel = model
                            record.cloudRuns?[index].upstreamProvider = provider
                            record.cloudRuns?[index].usage = usage
                        }
                    }
                }
            }
            throw error
        }
    }

    private func updateCloudRecord(_ update: (inout SongRecord) throws -> Void) throws {
        guard var record = song else { throw CloudError.configuration("歌曲已关闭。") }
        try update(&record)
        try record.save(in: root)
        song = record
    }

    func cancelCloud() {
        cloudTask?.cancel()
        if cloudTask != nil { cloudProgress = "正在取消…" }
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
            run(Self.defaultJobs, skipCompleted: true)
            response = ["track_id": doc.trackID, "status": activeJob == nil ? "ready" : "running"]
        } catch { response = ["error": error.localizedDescription] }
        if let data = try? JSONEncoder().encode(response) {
            try? serviceInput?.write(contentsOf: data + Data([10]))
        }
    }
    static let defaultJobs: [AnalysisJob] = [.acoustics, .structure, .rhythm, .harmony, .repetition, .events, .melody, .lyrics, .emotion]
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
    func stop() { cancel(); cancelCloud(); stopService(); modelEnvironment.cancel(); player?.stop() }
}
