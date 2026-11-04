import Foundation
import CryptoKit

struct ReviewedText: Codable, Equatable {
    var suggested: String?
    var confirmed: String?
    var hint: String?
    var value: String? { confirmed ?? suggested }
}

struct Mark: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: String
    var start: Double
    var end: Double
    var source: String
    var startConfirmed = false
    var endConfirmed = false
    var fields: [String: ReviewedText] = [:]
    var metrics: [String: Double] = [:]

    var label: String { fields["label"]?.value ?? kind }
    var reviewed: Bool {
        startConfirmed || endConfirmed || fields.values.contains { $0.confirmed != nil || $0.hint != nil }
    }
    func overlaps(_ range: Range<Double>) -> Bool {
        start == end ? range.contains(start) : start < range.upperBound && end > range.lowerBound
    }
    static func manual(_ kind: String, from: Double, to: Double, label: String) -> Mark {
        Mark(kind: kind, start: from, end: to, source: "user", startConfirmed: true, endConfirmed: true,
             fields: ["label": ReviewedText(confirmed: label)])
    }
}

enum AnalysisJob: String, CaseIterable, Identifiable {
    case structure, acoustics, harmony, lyrics, emotion, alignment
    var id: Self { self }
    var title: String {
        switch self {
        case .structure: "结构 · 节拍 · 分轨"
        case .acoustics: "声学特征"
        case .harmony: "调性与和弦"
        case .lyrics: "逐句歌词"
        case .emotion: "情绪标签与走势"
        case .alignment: "歌词字词对齐"
        }
    }
    var kinds: Set<String> {
        switch self {
        case .structure: ["section", "beat", "downbeat"]
        case .acoustics: ["acoustic", "onset"]
        case .harmony: ["chord"]
        case .lyrics: ["lyric", "word"]
        case .emotion: ["emotion"]
        case .alignment: ["word"]
        }
    }
}

struct JobResult: Codable {
    var marks: [Mark]
    var bpm: Double?
    var key: String?
    var stems: [String: String]?
}

struct SongRecord: Codable {
    var schemaVersion = 1
    var revision = 0
    var trackID: String
    var path: String
    var duration: Double
    var marks: [Mark] = []
    var status: [String: String] = [:]
    var bpm: Double?
    var key: String?
    var stems: [String: String] = [:]

    var sections: [Mark] { marks.filter { $0.kind == "section" }.sorted { $0.start < $1.start } }

    init(url: URL, duration: Double) {
        path = url.standardizedFileURL.resolvingSymlinksInPath().path
        trackID = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.duration = duration
        marks = [Mark(kind: "section", start: 0, end: duration, source: "initial",
                      fields: ["label": ReviewedText(suggested: "全曲")])]
    }

    mutating func split(_ id: String, at time: Double) {
        guard let i = marks.firstIndex(where: { $0.id == id }), time > marks[i].start, time < marks[i].end else { return }
        var right = marks[i]
        right.id = UUID().uuidString
        right.start = time
        right.startConfirmed = true
        marks[i].end = time
        marks[i].endConfirmed = true
        marks.append(right)
        if right.kind == "lyric" {
            // The original text cannot describe both halves after a manual split.
            marks[marks.count - 1].fields["label"] = ReviewedText(confirmed: "")
            invalidateWords(from: marks[i].start, to: right.end)
        }
    }

    mutating func moveBoundary(left id: String, to time: Double) {
        let ordered = sections
        guard let n = ordered.firstIndex(where: { $0.id == id }), n + 1 < ordered.count,
              time > ordered[n].start, time < ordered[n + 1].end,
              let left = marks.firstIndex(where: { $0.id == id }),
              let right = marks.firstIndex(where: { $0.id == ordered[n + 1].id }) else { return }
        marks[left].end = time
        marks[left].endConfirmed = true
        marks[right].start = time
        marks[right].startConfirmed = true
    }

    mutating func mergeNext(_ id: String) {
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
        let row = marks[i]
        guard let next = marks.filter({ $0.kind == row.kind && $0.start >= row.end && $0.id != id })
            .min(by: { $0.start < $1.start }) else { return }
        marks[i].end = next.end
        marks[i].endConfirmed = true
        if row.kind == "lyric" {
            marks[i].fields["label"] = ReviewedText(confirmed: [row.label, next.label].joined(separator: " "))
            invalidateWords(from: row.start, to: next.end)
        }
        marks.removeAll { $0.id == next.id }
    }

    /// Keep the neighbour's identity and annotations while absorbing the deleted interval.
    mutating func deleteSection(_ id: String) -> String? {
        let ordered = sections
        guard ordered.count > 1, let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let neighbour = ordered[index == 0 ? 1 : index - 1]
        guard let i = marks.firstIndex(where: { $0.id == neighbour.id }) else { return nil }
        if index == 0 {
            marks[i].start = ordered[index].start
            marks[i].startConfirmed = true
        } else {
            marks[i].end = ordered[index].end
            marks[i].endConfirmed = true
        }
        marks.removeAll { $0.id == id }
        return neighbour.id
    }

    mutating func invalidateWords(from start: Double, to end: Double) {
        marks.removeAll { $0.kind == "word" && $0.start < end && $0.end > start }
        status[AnalysisJob.alignment.rawValue] = "待更新"
    }

    mutating func apply(_ result: JobResult, job: AnalysisJob, range: Range<Double>) {
        let full = range.lowerBound == 0 && range.upperBound >= duration
        let keepSections = sections.contains(where: \.reviewed)
        // A late result only owns its module and interval. Reviewed fields retain their originals.
        let existing = marks.filter { job.kinds.contains($0.kind) && $0.overlaps(range) }
        marks.removeAll { job.kinds.contains($0.kind) && $0.overlaps(range) && !$0.reviewed
            && !(keepSections && $0.kind == "section") }
        for item in result.marks where item.start >= range.lowerBound && item.start < range.upperBound {
            var row = item
            row.end = min(row.end, range.upperBound)
            if row.kind == "section" && (keepSections || !full) { continue }
            if existing.contains(where: { old in
                old.reviewed && old.kind == row.kind && old.start < row.end && old.end > row.start
            }) { continue }
            marks.append(row)
        }
        if job == .structure && full {
            bpm = result.bpm
            if let stems = result.stems { self.stems = stems }
            if sections.isEmpty {
                marks.append(Mark(kind: "section", start: 0, end: duration, source: "initial"))
            }
        }
        if job == .harmony && full { key = result.key }
        status[job.rawValue] = result.marks.isEmpty ? "无可靠结果" : "完成"
    }

    func summary(for section: Mark) -> String {
        let range = section.start..<section.end
        let samples = marks.filter { $0.kind == "acoustic" && $0.overlaps(range) }
        let levels = samples.compactMap { $0.metrics["short_lufs"] }
        var parts: [String] = []
        if let first = levels.first, let last = levels.last {
            let delta = last - first
            parts.append(abs(delta) < 2 ? "响度较平稳" : delta > 0 ? "段尾响度上升" : "段尾响度减弱")
        }
        let emotion = marks.first { $0.kind == "emotion" && $0.overlaps(range) }
        if let mood = section.fields["mood"]?.value ?? emotion?.fields["label"]?.value, !mood.isEmpty {
            parts.append("听感 · " + mood)
        }
        if let note = section.fields["content"]?.value, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "，")
    }

    func agentMessage(mcpEndpoint: String) throws -> String {
        // Include the editorial work even when the receiving agent cannot reach the local MCP server.
        let annotations = marks.filter { $0.kind == "section" || $0.kind == "note" || $0.reviewed }
            .sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let snapshot = String(decoding: try encoder.encode(annotations), as: UTF8.self)
        let types = Set(annotations.map(\.kind)).union(["section", "note"]).sorted()
        let typesJSON = String(decoding: try encoder.encode(types), as: UTF8.self)
        let details = [bpm.map { "\($0) BPM" }, key].compactMap { $0 }.joined(separator: " · ")
        return """
        请按时间顺序整理《\(URL(fileURLWithPath: path).lastPathComponent)》的分段与标注。全曲时长 \(duration) 秒，当前保存修订号为 \(revision)。\(details.isEmpty ? "" : " " + details)
        请区分已确认内容（confirmed）、模型或初始建议（suggested）和待核对的人工提示（hint）。

        已连接本机 Music Intelligence Tool MCP（\(mcpEndpoint)）时，请按以下工具名和参数读取最新记录：
        get_music_overview {"track_id":"\(trackID)"}
        get_music_timeline {"track_id":"\(trackID)","start_s":0,"end_s":\(duration),"types":\(typesJSON),"confirmed_only":false}
        查询结果的 hints 是人工提示。请保留它们，并注明哪些判断需要试听核对。

        已保存的分段、注释及人工校对快照（时间单位为秒）：
        \(snapshot)
        """
    }

    mutating func save(in root: URL) throws {
        let dir = root.appendingPathComponent(trackID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var next = self
        next.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(next).write(to: dir.appendingPathComponent("analysis.json"), options: .atomic)
        revision = next.revision
    }
}
