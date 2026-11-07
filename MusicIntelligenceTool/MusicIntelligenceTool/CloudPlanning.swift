import Foundation

enum CloudAudioSource: String, Codable, CaseIterable, Identifiable {
    case original, vocals, drums, bass
    var id: Self { self }
    var title: String {
        switch self {
        case .original: "原曲"
        case .vocals: "人声轨"
        case .drums: "鼓轨"
        case .bass: "贝斯轨"
        }
    }
    var evidenceID: String { self == .original ? "audio" : "audio_" + rawValue }
}

struct CloudAudioReference: Codable, Equatable {
    var id: String
    var source: CloudAudioSource
    var range: AnalysisRange
}

struct CloudAudioAttachment {
    var reference: CloudAudioReference
    var data: Data
}

struct CloudTaskOptions: Codable, Equatable {
    var question = ""
    var focusRanges: [AnalysisRange] = []
    var audioSources: [CloudAudioSource] = []
    var inputInsightIDs: [String] = []
    var compactContext = false
    var missingRanges: [AnalysisRange] = []

    func validate(task: CloudTaskKind, range: AnalysisRange, duration: Double) throws {
        let ranges = focusRanges.isEmpty ? [range] : focusRanges
        guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end <= duration, range.duration > 0,
              ranges.count <= 100, ranges.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= range.start && $0.end <= range.end && $0.duration > 0 }),
              Set(audioSources).count == audioSources.count,
              question.count <= 4000 else { throw CloudError.configuration("分析范围、音频来源或提示不合法。") }
        if task == .question && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CloudError.configuration("请填写需要核对的提示。")
        }
        if task == .comparison {
            guard ranges.count == 2, ranges[0].end <= ranges[1].start, audioSources.isEmpty else {
                throw CloudError.configuration("请选择两个不同且不重叠的段落。段落比较仅发送这两段的数据和已有解读。")
            }
        }
        if task == .audio && audioSources.isEmpty { throw CloudError.configuration("请选择至少一种音频来源。") }
        if [.interpretation, .overview].contains(task) && !audioSources.isEmpty {
            throw CloudError.configuration("此任务只解读记录，不能携带音频。")
        }
    }
}

struct CloudBatchPlan {
    var ranges: [AnalysisRange]
    var audioSources: [CloudAudioSource]
    var maximumRequests: Int
    var requestCount: Int { ranges.count + 1 }

    static func make(song: SongRecord, connection: ModelConnection, windowSeconds: Double,
                     audioSources: [CloudAudioSource], maximumRequests: Int) throws -> CloudBatchPlan {
        guard windowSeconds.isFinite, (1...600).contains(windowSeconds), (2...50).contains(maximumRequests),
              song.duration.isFinite, song.duration > 0, Set(audioSources).count == audioSources.count else {
            throw CloudError.configuration("窗口须为 1–600 秒，每批请求上限为 2–50 次。")
        }
        let sources = Double(max(1, audioSources.count))
        // Every attachment is 24 kHz stereo PCM16; reserve WAV headers inside
        // the same 20 MB payload ceiling enforced by the transport boundary.
        let audioLimit = min(connection.maxAudioSeconds / sources, (20 * 1024 * 1024 - 4096) / (96000 * sources))
        let window = audioSources.isEmpty ? windowSeconds : min(windowSeconds, audioLimit)
        guard window >= 0.1 else { throw CloudError.configuration("音频上限过小，无法规划片段。") }
        let boundaries = Set([0, song.duration] + song.sections.flatMap { [$0.start, $0.end] })
            .filter { $0 >= 0 && $0 <= song.duration }.sorted()
        var ranges: [AnalysisRange] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            var cursor = start
            while cursor < end - 0.000001 {
                let stop = min(end, cursor + window)
                ranges.append(AnalysisRange(start: cursor, end: stop))
                guard ranges.count + 1 <= maximumRequests else {
                    throw CloudError.configuration("整曲需要超过 \(maximumRequests) 次请求（含最终汇总）。请增大窗口或请求上限。")
                }
                cursor = stop
            }
        }
        return CloudBatchPlan(ranges: ranges, audioSources: audioSources, maximumRequests: maximumRequests)
    }
}

struct CloudBatch: Codable, Identifiable {
    var id = UUID().uuidString
    var createdAt = Date()
    var ranges: [AnalysisRange]
    var audioSources: [CloudAudioSource]
    var maximumRequests: Int
    var submittedRequests = 0
    var runIDs: [String] = []
    var summaryRunID: String?
    var status = "分析中"
    var message: String?
    var mode: String?
}

extension SongRecord {
    func currentInsightIDs(in ranges: [AnalysisRange]) -> [String] {
        marks.filter { row in
            let task = cloudRuns?.first { $0.id == row.fields["label"]?.origin?.runID }?.task
            if task == .overview || task == .comparison { return false }
            return row.kind == "insight" && ranges.contains(where: { row.overlaps($0.interval) }) &&
            ["label", "content"].contains(where: { row.fields[$0]?.value?.isEmpty == false })
        }.map(\.id).sorted()
    }

    /// These are explicitly named interval means, not integrated LUFS. Coverage
    /// accompanies every statistic so missing samples never become silence.
    func sectionMetrics(in range: AnalysisRange) -> [String: Double] {
        sectionMetrics(in: [range])
    }

    func sectionMetrics(in ranges: [AnalysisRange], containedSamplesOnly: Bool = false) -> [String: Double] {
        let selected = Self.mergedRanges(ranges)
        let duration = selected.reduce(0) { $0 + $1.duration }
        guard duration > 0 else { return [:] }
        var result: [String: Double] = [:]
        let measurements = ["short_lufs", "rms", "low_share", "onsets_per_s", "centroid_hz"].map { ("acoustic", $0) } + [("tempo", "tempo_bpm"), ("pitch", "midi_pitch")]
        for (kind, key) in measurements {
            let samples = marks.filter { row in
                row.kind == kind && row.analysisStale != true && selected.contains { scope in
                    containedSamplesOnly ? scope.contains(row) : row.overlaps(scope.interval)
                }
            }
            var sum = 0.0, weight = 0.0
            for sample in samples {
                guard let value = sample.metrics[key] else { continue }
                let length = selected.reduce(0.0) { $0 + max(0, min(sample.end, $1.end) - max(sample.start, $1.start)) }
                if length > 0 { sum += value * length; weight += length }
            }
            if weight > 0 {
                result["mean_" + key] = sum / weight
                result["coverage_" + key] = min(1, weight / duration)
            }
        }
        for source in ["vocals", "drums", "bass", "silence"] {
            let measured = (coverage?["events"] ?? []).filter { $0.source == source }
                .flatMap { span in selected.map { AnalysisRange(start: max($0.start, span.start), end: min($0.end, span.end)) } }
                .filter { $0.duration > 0 }
            let covered = Self.unionDuration(measured)
            guard covered > 0 else { continue }
            let active = marks.filter { $0.kind == "event" && $0.analysisStale != true && $0.fields["event_type"]?.value == source }
                .flatMap { row in measured.map { AnalysisRange(start: max(row.start, $0.start), end: min(row.end, $0.end)) } }
                .filter { $0.duration > 0 }
            result[source + "_activity_fraction"] = min(1, Self.unionDuration(active) / covered)
            result[source + "_coverage"] = min(1, covered / duration)
        }
        return result
    }

    private static func unionDuration(_ ranges: [AnalysisRange]) -> Double {
        mergedRanges(ranges).reduce(0) { $0 + $1.duration }
    }

    private static func mergedRanges(_ ranges: [AnalysisRange]) -> [AnalysisRange] {
        var merged: [AnalysisRange] = []
        for range in ranges.filter({ $0.duration > 0 }).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end { merged[merged.count - 1].end = max(last.end, range.end) }
            else { merged.append(range) }
        }
        return merged
    }

    func unanalyzedRanges(in range: AnalysisRange, runIDs: Set<String>? = nil) -> [AnalysisRange] {
        let measured = (cloudRuns ?? []).filter { run in
            (runIDs == nil || runIDs?.contains(run.id) == true) && [.audio, .interpretation].contains(run.task) && ["完成", "无可靠结果"].contains(run.status)
        }.flatMap { $0.options?.focusRanges.isEmpty == false ? $0.options?.focusRanges ?? [] : [$0.range] }
            .map { AnalysisRange(start: max(range.start, $0.start), end: min(range.end, $0.end)) }
        var cursor = range.start
        var gaps: [AnalysisRange] = []
        for span in Self.mergedRanges(measured) {
            if span.start > cursor { gaps.append(AnalysisRange(start: cursor, end: span.start)) }
            cursor = max(cursor, span.end)
        }
        if cursor < range.end { gaps.append(AnalysisRange(start: cursor, end: range.end)) }
        return gaps
    }
}
