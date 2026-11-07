import SwiftUI

struct ModelComparisonPanel: View {
    let studio: Studio
    let song: SongRecord
    @State private var selection = ""
    private var comparisons: [CloudBatch] { (song.cloudBatches ?? []).filter { $0.mode == "models" } }
    private var current: CloudBatch? { comparisons.first { $0.id == selection } ?? comparisons.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let batch = current {
                Picker("对照记录", selection: $selection) {
                    ForEach(comparisons.reversed()) { row in
                        Text(row.createdAt.formatted(date: .omitted, time: .shortened) + " · " + row.status).tag(row.id)
                    }
                }
                Text("同一输入独立分析；分歧需要试听核对，模型一致也不等于人工确认。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(batch.runIDs, id: \.self) { id in
                        if let run = song.cloudRuns?.first(where: { $0.id == id }) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text((run.endpointHost ?? run.provider) + " / " + (run.actualModel ?? run.model)).font(.headline).textSelection(.enabled)
                                    Text("接入渠道：" + run.provider + (run.upstreamProvider.map { " · 上游：" + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                                    Text(run.status).font(.caption).foregroundStyle(.secondary)
                                    Text(clockText(run.range.start) + " — " + clockText(run.range.end)).font(.caption.monospacedDigit())
                                    if let message = run.message { Text(message).font(.caption).foregroundStyle(.orange) }
                                    let findings = song.marks.filter { $0.fields["label"]?.origin?.runID == id }
                                    if findings.isEmpty { Text("尚无可展示的结论").foregroundStyle(.secondary) }
                                    ForEach(findings) { row in
                                        Divider()
                                        Text(row.fields["label"]?.suggested ?? row.label).font(.callout.bold())
                                        Text(row.fields["content"]?.suggested ?? "").font(.callout).textSelection(.enabled)
                                        if let uncertainty = row.fields["content"]?.origin?.uncertainty, !uncertainty.isEmpty {
                                            Text("不确定处：" + uncertainty).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Button("校对此条") { studio.select(row) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                Text("尚无双模型对照。在“外部模型分析”中启用同一输入双模型对照后，结果会并排显示。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .onAppear { selection = comparisons.last?.id ?? "" }
        .onChange(of: comparisons.count) { selection = comparisons.last?.id ?? "" }
    }
}
