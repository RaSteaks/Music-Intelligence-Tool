import Foundation
import CryptoKit

struct ReviewedText: Codable, Equatable {
    var suggested: String?
    var confirmed: String?
    var hint: String?
    var origin: SuggestionOrigin?
    var rejected: Bool?
    var suggestionAvailable: Bool { rejected != true && origin?.stale != true }
    var value: String? { confirmed ?? (suggestionAvailable ? suggested : nil) }
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
    var analysisStale: Bool?
    var relatedIDs: [String]?

    var label: String {
        if let confirmed = fields["label"]?.confirmed { return confirmed }
        if analysisStale == true { return "待更新的分析" }
        if let value = fields["label"]?.value { return value }
        if let field = fields["label"], field.suggested == nil { return "" }
        if kind == "insight" { return fields["label"]?.origin?.stale == true ? "待更新的解读" : "已拒绝的解读" }
        return kind
    }
    /// Analysis merging protects any human input, including boundaries and hints.
    var reviewed: Bool {
        startConfirmed || endConfirmed || fields.values.contains { $0.confirmed != nil || $0.hint != nil || $0.rejected == true }
    }
    var reviewStatus: ReviewStatus {
        let content = fields["content"]
        let field = kind == "insight" && (content?.confirmed != nil || content?.suggested != nil) ? content : fields["label"]
        let hasText = field?.confirmed?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let noteHasContent = kind == "note" && fields["content"]?.confirmed?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let vocalState = fields["vocal_state"]?.confirmed
        if hasText || noteHasContent || (kind == "lyric" && (vocalState == "纯器乐" || vocalState == "有演唱但听不清")) {
            return .confirmed
        }
        if analysisStale == true || field?.origin?.stale == true { return .stale }
        if field?.rejected == true { return .rejected }
        if ["lyric", "note", "section"].contains(kind), field?.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .unfilled
        }
        return reviewed ? .edited : .pending
    }

    var timeRange: ClosedRange<Double> { start...end }

    func overlaps(_ range: Range<Double>) -> Bool {
        start == end ? range.contains(start) : start < range.upperBound && end > range.lowerBound
    }
    static func manual(_ kind: String, from: Double, to: Double, label: String) -> Mark {
        // An empty label is an unfilled slot, not a confirmed clear.
        Mark(kind: kind, start: from, end: to, source: "user", startConfirmed: true, endConfirmed: true,
             fields: ["label": label.isEmpty ? ReviewedText() : ReviewedText(confirmed: label)])
    }
}

enum ReviewStatus {
    case unfilled, pending, edited, confirmed, rejected, stale

    var needsReview: Bool { self != .confirmed && self != .rejected }

    var title: String {
        switch self {
        case .unfilled: "待填写"
        case .pending: "待核对"
        case .edited: "已修改，待核对"
        case .confirmed: "已确认"
        case .rejected: "已拒绝"
        case .stale: "待更新"
        }
    }
}

enum AnalysisJob: String, CaseIterable, Identifiable {
    case structure, acoustics, rhythm, harmony, repetition, melody, lyrics, emotion, events, alignment
    var id: Self { self }
    var requiresWholeTrack: Bool { self == .structure || self == .repetition }
    var title: String {
        switch self {
        case .structure: "结构 · 节拍 · 分轨"
        case .acoustics: "声学特征"
        case .harmony: "调性与和弦"
        case .rhythm: "节奏与律动"
        case .repetition: "重复结构与段落关系（全曲）"
        case .melody: "主导旋律与音域"
        case .lyrics: "逐句歌词"
        case .emotion: "情绪标签与走势"
        case .events: "声部活动与停顿"
        case .alignment: "歌词字词对齐"
        }
    }
    var kinds: Set<String> {
        switch self {
        case .structure: ["section", "beat", "downbeat"]
        case .acoustics: ["acoustic", "onset", "loudness"]
        case .harmony: ["chord", "key", "key_region", "modulation"]
        case .rhythm: ["rhythm_beat", "tempo", "rhythm_summary"]
        case .repetition: ["repetition"]
        case .melody: ["pitch", "melody_note", "melody_summary", "melody_phrase", "melody_motif"]
        case .lyrics: ["lyric", "word"]
        case .emotion: ["emotion"]
        case .events: ["event"]
        case .alignment: ["word"]
        }
    }
}

struct JobResult: Codable {
    var marks: [Mark]
    var bpm: Double?
    var key: String?
    var stems: [String: String]?
    var warnings: [String]?
    var coverage: [AnalysisCoverage]?
}

struct AnalysisCoverage: Codable, Equatable {
    var source: String
    var start: Double
    var end: Double
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
    var cloudRuns: [CloudRun]?
    var cloudBatches: [CloudBatch]?
    var warnings: [String: [String]]?
    var coverage: [String: [AnalysisCoverage]]?
    var completedRanges: [String: AnalysisRange]?

    var sections: [Mark] { marks.filter { $0.kind == "section" }.sorted { $0.start < $1.start } }

    func hasCompleted(_ job: AnalysisJob, in range: ClosedRange<Double>) -> Bool {
        guard ["完成", "无可靠结果"].contains(status[job.rawValue]) else { return false }
        if let completed = completedRanges?[job.rawValue] {
            return completed.start <= range.lowerBound && completed.end >= range.upperBound
        }
        // Older records only prove coverage for modules that always ran on the whole track.
        return job.requiresWholeTrack
    }

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
            // The original text cannot describe both halves after a manual split; the new half starts unfilled.
            marks[marks.count - 1].fields["label"] = ReviewedText()
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
        let refreshable = [AnalysisJob.events, .rhythm, .harmony, .repetition, .melody].contains(job)
        let oldRhythmBeats = marks.filter { $0.kind == "rhythm_beat" }.map(\.start)
        // Constant interval candidates can retain their unanalysed portions.
        // Whole-range summaries and phrases cannot be trimmed this way.
        let splittable: Set<String> = ["event", "chord", "melody_note", "pitch", "tempo"]
        let remaining = existing.filter { splittable.contains($0.kind) && !$0.reviewed }.flatMap { old -> [Mark] in
            var pieces: [Mark] = []
            if old.start < range.lowerBound { var left = old; left.end = range.lowerBound; pieces.append(left) }
            if old.end > range.upperBound { var right = old; right.id = UUID().uuidString; right.start = range.upperBound; pieces.append(right) }
            return pieces
        }
        marks.removeAll { job.kinds.contains($0.kind) && $0.overlaps(range) && !$0.reviewed
            && !(keepSections && $0.kind == "section") && !(job == .harmony && !full && $0.kind == "key") }
        marks += remaining
        for item in result.marks where item.start >= range.lowerBound && item.start < range.upperBound {
            var row = item
            row.end = min(row.end, range.upperBound)
            if job == .harmony && !full && row.kind == "key" { row.kind = "key_region" }
            if row.kind == "section" && (keepSections || !full) { continue }
            if let old = existing.first(where: { old in
                old.reviewed && old.kind == row.kind && old.start < row.end && old.end > row.start
                    && (row.kind != "event" || old.fields["event_type"]?.value == row.fields["event_type"]?.value)
            }) {
                if refreshable, old.source != "user", old.start == row.start, old.end == row.end, old.relatedIDs == row.relatedIDs,
                   let index = marks.firstIndex(where: { $0.id == old.id }) {
                    for (field, value) in row.fields {
                        marks[index].fields[field, default: ReviewedText()].suggested = value.suggested
                    }
                    marks[index].metrics = row.metrics
                    marks[index].source = row.source
                    marks[index].analysisStale = false
                    continue
                }
                // If refreshed boundaries differ, retain the reviewed old event
                // and expose the fresh candidate separately for realignment.
                if refreshable, old.source != "user", let index = marks.firstIndex(where: { $0.id == old.id }) {
                    marks[index].analysisStale = true
                } else { continue }
            }
            marks.append(row)
        }
        if job == .structure && full {
            bpm = result.bpm
            if let stems = result.stems {
                self.stems = stems
                invalidateAnalysis(.events)
                invalidateAnalysis(.melody)
            }
            for dependent in [AnalysisJob.rhythm, .harmony, .repetition] { invalidateAnalysis(dependent) }
            if sections.isEmpty {
                marks.append(Mark(kind: "section", start: 0, end: duration, source: "initial"))
            }
        }
        if job == .harmony && full { key = result.key }
        if job == .rhythm, !marks.contains(where: { $0.kind == "beat" }), oldRhythmBeats != marks.filter({ $0.kind == "rhythm_beat" }).map(\.start) {
            invalidateAnalysis(.harmony)
        }
        if warnings == nil { warnings = [:] }
        warnings?[job.rawValue] = result.warnings ?? []
        if let measured = result.coverage {
            let previous = coverage?[job.rawValue] ?? []
            let retained = previous.flatMap { old -> [AnalysisCoverage] in
                if old.end <= range.lowerBound || old.start >= range.upperBound { return [old] }
                var parts: [AnalysisCoverage] = []
                if old.start < range.lowerBound { parts.append(AnalysisCoverage(source: old.source, start: old.start, end: range.lowerBound)) }
                if old.end > range.upperBound { parts.append(AnalysisCoverage(source: old.source, start: range.upperBound, end: old.end)) }
                return parts
            }
            if coverage == nil { coverage = [:] }
            coverage?[job.rawValue] = retained + measured
        }
        // Local requests may replace aggregates that span the selection. Adjacent
        // local results cannot be used as proof of a completed whole-track run.
        if completedRanges == nil { completedRanges = [:] }
        completedRanges?[job.rawValue] = AnalysisRange(start: range.lowerBound, end: range.upperBound)
        status[job.rawValue] = result.marks.isEmpty ? "无可靠结果" : "完成"
    }

    mutating func invalidateAnalysis(_ job: AnalysisJob, kinds: Set<String>? = nil) {
        guard status[job.rawValue] != nil else { return }
        status[job.rawValue] = "待更新"
        completedRanges?.removeValue(forKey: job.rawValue)
        if job == .harmony && (kinds == nil || kinds?.contains("key") == true) { key = nil }
        for index in marks.indices where (kinds ?? job.kinds).contains(marks[index].kind) && marks[index].source != "user" {
            marks[index].analysisStale = true
        }
        coverage?[job.rawValue] = []
    }

    func summary(for section: Mark) -> String {
        guard section.end > section.start else { return "" }
        let range = section.start..<section.end
        let third = (section.end - section.start) / 3
        let beginning = section.start..<(section.start + third)
        let ending = (section.end - third)..<section.end
        var parts: [String] = []
        if let first = averageMetric("short_lufs", kind: "acoustic", range: beginning),
           let last = averageMetric("short_lufs", kind: "acoustic", range: ending) {
            let delta = last - first
            parts.append(abs(delta) < 2 ? "响度较平稳" : delta > 0 ? "段尾响度上升" : "段尾响度减弱")
        }
        if let first = averageMetric("onsets_per_s", kind: "acoustic", range: beginning),
           let last = averageMetric("onsets_per_s", kind: "acoustic", range: ending), abs(last - first) >= 1 {
            parts.append(last > first ? "段尾起音更密集" : "段尾起音更稀疏")
        }
        var moods: [String: Double] = [:]
        for row in marks where row.kind == "emotion" && row.overlaps(range) && (row.analysisStale != true || row.fields["label"]?.confirmed != nil) {
            if let mood = row.fields["label"]?.value, !mood.isEmpty {
                moods[mood, default: 0] += min(row.end, section.end) - max(row.start, section.start)
            }
        }
        let dominant = moods.keys.sorted().max { moods[$0, default: 0] < moods[$1, default: 0] }
        if let mood = section.fields["mood"]?.value ?? dominant, !mood.isEmpty {
            parts.append("主要听感 · " + mood)
        }
        if let first = averageMetric("arousal", kind: "emotion", range: beginning),
           let last = averageMetric("arousal", kind: "emotion", range: ending), abs(last - first) >= 1 {
            parts.append(last > first ? "模型唤醒度上升" : "模型唤醒度下降")
        }
        if let note = section.fields["content"]?.value, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: "，")
    }

    private func averageMetric(_ key: String, kind: String, range: Range<Double>) -> Double? {
        var weighted = 0.0
        var covered = 0.0
        for row in marks where row.kind == kind && row.overlaps(range) && row.analysisStale != true {
            guard let value = row.metrics[key] else { continue }
            let overlap = min(row.end, range.upperBound) - max(row.start, range.lowerBound)
            guard overlap > 0 else { continue }
            weighted += value * overlap
            covered += overlap
        }
        // Missing startup windows are unavailable data, never zero loudness.
        return covered >= (range.upperBound - range.lowerBound) * 0.25 && covered > 0 ? weighted / covered : nil
    }

    func agentMessage(mcpEndpoint: String) throws -> String {
        // The manual fallback preserves the same complete record as the MCP handoff.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let snapshot = String(decoding: try encoder.encode(self), as: UTF8.self)
        let details = [bpm.map { "\($0) BPM" }, key].compactMap { $0 }.joined(separator: " · ")
        return """
        请按时间顺序整理《\(URL(fileURLWithPath: path).lastPathComponent)》的分段与标注。全曲时长 \(duration) 秒，当前保存修订号为 \(revision)。\(details.isEmpty ? "" : " " + details)
        请区分已确认内容（confirmed）、模型或初始建议（suggested）和待核对的人工提示（hint）。

        已连接本机 Music Intelligence Tool MCP（\(mcpEndpoint)）时，请按以下工具名和参数读取最新记录：
        get_music_record {"track_id":"\(trackID)"}
        请保留人工提示，并注明哪些判断需要试听核对。本地音频和分轨仅包含路径，不包含音频文件内容。

        已保存的完整分析记录快照（时间单位为秒）：
        \(snapshot)
        """
    }

    mutating func save(in root: URL) throws {
        let dir = root.appendingPathComponent(trackID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var next = self
        next.reconcileCloudResults()
        if next.cloudBatches != nil || next.coverage != nil || next.completedRanges != nil || next.cloudRuns?.contains(where: { $0.options != nil }) == true {
            next.schemaVersion = max(next.schemaVersion, 3)
        } else if next.cloudRuns != nil { next.schemaVersion = max(next.schemaVersion, 2) }
        next.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(next).write(to: dir.appendingPathComponent("analysis.json"), options: .atomic)
        self = next
    }
}
