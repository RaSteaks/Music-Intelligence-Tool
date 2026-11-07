import Foundation
import CryptoKit

enum CloudTaskKind: String, Codable, CaseIterable, Identifiable {
    case interpretation, audio, question, comparison, overview
    var id: Self { self }
    var title: String {
        switch self {
        case .interpretation: "解读已有结果"
        case .audio: "分析选区音频"
        case .question: "核对提示"
        case .comparison: "比较两个段落"
        case .overview: "汇总已有解读"
        }
    }
}

struct AnalysisRange: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
    var interval: Range<Double> { start..<end }
    func contains(_ row: Mark) -> Bool {
        row.start >= start && row.end <= end && row.overlaps(interval)
    }
}

struct SuggestionOrigin: Codable, Equatable {
    var runID: String
    var provider: String
    var model: String
    var evidenceIDs: [String]
    var uncertainty: String
    var stale = false
}

struct CloudRun: Codable, Identifiable {
    var id = UUID().uuidString
    var task: CloudTaskKind
    var provider: String
    var model: String
    var actualModel: String?
    var upstreamProvider: String?
    var range: AnalysisRange
    var inputRevision: Int
    var inputFingerprint: String
    var audioFingerprint: String?
    var requestFingerprint: String?
    var promptVersion = "music-insights-v1"
    var createdAt = Date()
    var finishedAt: Date?
    var status = "准备中"
    var message: String?
    var usage: [String: Double]?
    var context: CloudContext?
    var endpointHost: String?
    var options: CloudTaskOptions?
    var batchID: String?

    var hasCurrentResult: Bool { status == "完成" || status == "无可靠结果" }
}

/// Only task-relevant data crosses the cloud boundary. Paths, credentials and
/// unrelated marks never appear in this representation.
struct CloudContext: Codable {
    struct Item: Codable {
        struct Field: Codable {
            var suggested: String?
            var confirmed: String?
            var hint: String?
        }
        var id: String
        var kind: String
        var start: Double
        var end: Double
        var source: String
        var fields: [String: Field]
        var metrics: [String: Double]
    }
    var range: AnalysisRange
    var bpm: Double?
    var key: String?
    var status: [String: String]
    var items: [Item]
    var focusRanges: [AnalysisRange]?
    var question: String?
    var audioReferences: [CloudAudioReference]?
    var missingRanges: [AnalysisRange]?
    var warnings: [String: [String]]?
    var coverage: [String: [AnalysisCoverage]]?

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct CloudFinding: Codable {
    var category: String
    var start: Double
    var end: Double
    var label: String
    var content: String
    var uncertainty: String
    var evidenceIDs: [String]
}

struct CloudAnswer: Codable {
    var findings: [CloudFinding]

    func validated(context: CloudContext, task: CloudTaskKind) throws -> CloudAnswer {
        let categories: Set<String> = ["summary", "instrument", "arrangement", "emotion", "lyric", "event"]
        let evidence = Set(context.items.map(\.id)).union(context.audioReferences?.map(\.id) ?? (task == .audio ? ["audio"] : []))
        guard findings.count <= 100 else { throw CloudError.invalidResult("分析条目超过上限。") }
        for finding in findings {
            guard categories.contains(finding.category), finding.start.isFinite, finding.end.isFinite,
                  finding.start >= context.range.start, finding.end <= context.range.end,
                  finding.start < finding.end,
                  !finding.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  finding.label.count <= 200, finding.content.count <= 6000, finding.uncertainty.count <= 2000,
                  !finding.evidenceIDs.isEmpty, Set(finding.evidenceIDs).isSubset(of: evidence) else {
                throw CloudError.invalidResult("模型返回了越界时间、无效字段或无法定位的证据。")
            }
            if finding.category != "summary", let ranges = context.focusRanges,
               !ranges.contains(where: { finding.start >= $0.start && finding.end <= $0.end }) {
                throw CloudError.invalidResult("模型将音乐事件定位到了未选择的区间。")
            }
        }
        return self
    }
}

extension SongRecord {
    func cloudContext(in range: AnalysisRange, options: CloudTaskOptions? = nil) -> CloudContext {
        let requestedScopes = options?.focusRanges ?? []
        let usesExplicitScopes = !requestedScopes.isEmpty
        let scopes = usesExplicitScopes ? requestedScopes : [range]
        let dependencies = Set(options?.inputInsightIDs ?? [])
        let compact = options?.compactContext == true
        let items = marks.filter { row in
            guard (row.kind != "insight" || dependencies.contains(row.id)), row.kind != "pitch",
                  !(compact && ["acoustic", "beat", "rhythm_beat", "downbeat", "onset", "word", "tempo", "melody_note"].contains(row.kind)) else { return false }
            // Text and interval measurements cannot be split across disjoint
            // selections. Integrated loudness always belongs to its full span.
            if usesExplicitScopes || row.kind == "loudness" { return scopes.contains { $0.contains(row) } }
            return row.overlaps(range.interval)
        }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
            .map { row in
                var metrics = row.analysisStale == true ? [:] : row.metrics
                if options != nil && row.kind == "section" {
                    let selected = scopes.map { AnalysisRange(start: max($0.start, row.start), end: min($0.end, row.end)) }.filter { $0.duration > 0 }
                    metrics.merge(sectionMetrics(in: selected, containedSamplesOnly: usesExplicitScopes)) { _, new in new }
                }
                return CloudContext.Item(id: row.id, kind: row.kind, start: max(range.start, row.start),
                                  end: min(range.end, row.end), source: row.source,
                                  fields: row.fields.mapValues { field in
                    CloudContext.Item.Field(suggested: field.suggestionAvailable && row.analysisStale != true ? field.suggested : nil,
                                            confirmed: field.confirmed, hint: field.hint)
                }, metrics: metrics)
            }
        return CloudContext(range: range, bpm: usesExplicitScopes ? nil : bpm, key: usesExplicitScopes ? nil : key,
                            status: usesExplicitScopes ? [:] : status.mapValues { $0.components(separatedBy: " · ").first ?? $0 }, items: items,
                            focusRanges: options.map { $0.focusRanges.isEmpty ? [range] : $0.focusRanges },
                            question: options?.question,
                            audioReferences: options?.audioSources.map { CloudAudioReference(id: $0.evidenceID, source: $0, range: range) },
                            missingRanges: options?.missingRanges,
                            warnings: options == nil || usesExplicitScopes ? nil : warnings,
                            coverage: options == nil ? nil : coverage?.mapValues { spans in
                                spans.flatMap { span in scopes.map {
                                    AnalysisCoverage(source: span.source, start: max(span.start, $0.start), end: min(span.end, $0.end))
                                }.filter { $0.end > $0.start } }
                            })
    }

    func cloudInputFingerprint(in range: AnalysisRange, options: CloudTaskOptions? = nil) throws -> String {
        var data = try cloudContext(in: range, options: options).data()
        // The audio digest is computed for cache reuse before uploading. The
        // file stamp also catches ordinary in-place edits during a live task.
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size)|\(modified)"
        data.append(Data(stamp.utf8))
        for source in options?.audioSources.filter({ $0 != .original }) ?? [] {
            guard let file = stems[source.rawValue] else { throw CloudError.configuration("缺少\(source.title)，请先运行分轨分析。") }
            let values = try FileManager.default.attributesOfItem(atPath: file)
            data.append(Data("\(source.rawValue)|\((values[.size] as? NSNumber)?.int64Value ?? 0)|\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)".utf8))
        }
        return Self.digest(data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func hasCurrentCloudRuns(_ ids: [String]) -> Bool {
        let current = Set((cloudRuns ?? []).filter(\.hasCurrentResult).map(\.id))
        return ids.allSatisfy(current.contains)
    }

    mutating func reconcileCloudResults() {
        guard var runs = cloudRuns else { return }
        for index in runs.indices where ["完成", "无可靠结果", "待更新"].contains(runs[index].status) {
            let current = try? cloudInputFingerprint(in: runs[index].range, options: runs[index].options)
            if current != runs[index].inputFingerprint { runs[index].status = "待更新" }
            // Runs only depend on already-existing findings, so append order is
            // dependency order. Propagate before evaluating a later summary.
            if runs[index].status == "待更新" {
                for markIndex in marks.indices {
                    for field in marks[markIndex].fields.keys where marks[markIndex].fields[field]?.origin?.runID == runs[index].id {
                        marks[markIndex].fields[field]?.origin?.stale = true
                    }
                }
            }
        }
        let stale = Set(runs.filter { $0.status == "待更新" }.map(\.id))
        for index in marks.indices {
            for field in marks[index].fields.keys {
                if let origin = marks[index].fields[field]?.origin, stale.contains(origin.runID) {
                    marks[index].fields[field]?.origin?.stale = true
                }
            }
        }
        cloudRuns = runs
        for index in cloudBatches?.indices ?? 0..<0 where cloudBatches?[index].status == "完成" {
            let dependencies = Set(cloudBatches?[index].runIDs ?? [])
            if runs.contains(where: { dependencies.contains($0.id) && $0.status == "待更新" }) {
                cloudBatches?[index].status = "待更新"
            }
        }
    }

    mutating func applyCloud(_ answer: CloudAnswer, runID: String) throws {
        guard let index = cloudRuns?.firstIndex(where: { $0.id == runID }), let run = cloudRuns?[index] else {
            throw CloudError.invalidResult("分析任务记录已不存在。")
        }
        let stale = try cloudInputFingerprint(in: run.range, options: run.options) != run.inputFingerprint
        for finding in answer.findings {
            let origin = SuggestionOrigin(runID: run.id, provider: run.provider, model: run.actualModel ?? run.model,
                                          evidenceIDs: finding.evidenceIDs, uncertainty: finding.uncertainty, stale: stale)
            // Separate insight marks avoid changing section identities or
            // overwriting confirmed labels while a request is running.
            marks.append(Mark(kind: "insight", start: finding.start, end: finding.end,
                              source: "\(run.provider)/\(run.actualModel ?? run.model)",
                              fields: ["label": ReviewedText(suggested: finding.label, origin: origin),
                                       "content": ReviewedText(suggested: finding.content, origin: origin),
                                       "category": ReviewedText(suggested: finding.category, origin: origin)]))
        }
        cloudRuns?[index].status = stale ? "待更新" : answer.findings.isEmpty ? "无可靠结果" : "完成"
        cloudRuns?[index].finishedAt = Date()
    }
}
