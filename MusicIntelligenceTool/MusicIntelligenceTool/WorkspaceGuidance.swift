import SwiftUI

/// The walkthrough runs in the real editor, using the bundled track and its saved marks.
enum StudyStep: Equatable {
    case locate, listen(String), annotate(String), finished

    var instruction: String {
        switch self {
        case .locate: "选中一个段落，看看它在时间轴上的位置。"
        case .listen: "循环试听这一段，可以反复核对听到的内容。"
        case .annotate: "把听感记在这个时间范围内，之后可以在右侧修改。"
        case .finished: "注释已自动保存。可在右侧修改，或从「导出与分享」查看结果。"
        }
    }

    var action: String {
        switch self {
        case .locate: "定位一个段落"
        case .listen: "试听本条"
        case .annotate: "添加注释「听过这段」"
        case .finished: "查看交付预览"
        }
    }
}

struct StudyGuide: View {
    let step: StudyStep
    let advance: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.instruction).font(.callout)
                .accessibilityIdentifier("studyInstruction")
            HStack {
                Button(step.action, action: advance).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("studyNext")
                Button(step == .finished ? "完成体验" : "跳过引导", action: close)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Tone.sound.color.opacity(0.08))
    }
}

struct WorkspaceScopeBar: View {
    let studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let row = studio.row {
                    Label("选中 \(row.displayName)", systemImage: "scope")
                        .lineLimit(1).help(row.displayName)
                        .accessibilityIdentifier("currentRecordScope")
                } else {
                    Text("未选条目").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let scope = studio.analysisScope {
                    Text("分析范围 · " + scope.title)
                        .monospacedDigit().lineLimit(1).help(scope.title)
                        .accessibilityIdentifier("currentAnalysisScope")
                        .layoutPriority(1)
                }
            }
            if studio.loop {
                let range = studio.loopRange.flatMap { $0.lowerBound < $0.upperBound ? $0 : nil }
                Label(range.map { "循环试听 · " + timeRangeText($0) } ?? "循环试听 · 请选择有时长的范围", systemImage: "repeat")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityIdentifier("loopScope")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct AnalysisOutcomeBar: View {
    let result: LocalAnalysisResult
    let categories: [CatalogCategory]
    let onView: (CatalogCategory) -> Void
    let onDetails: () -> Void
    let onClose: () -> Void

    private var failed: Int { result.states.values.filter { $0.hasPrefix("失败") || $0 == "未保存结果" }.count }
    private var noResults: Bool { result.states.values.allSatisfy { $0 == "无可靠结果" } }
    private var needsRefresh: Bool { result.states.values.contains("待更新") }
    private var title: String {
        if result.cancelled { return "已取消分析" }
        if failed > 0 { return "分析结束，\(failed) 项未完成" }
        if needsRefresh { return "分析结束，有结果待更新" }
        if noResults { return "分析完成，未找到可靠结果" }
        return "分析完成"
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: failed > 0 || needsRefresh || result.cancelled ? "exclamationmark.circle" : "checkmark.circle")
                .lineLimit(1).help(title + " · " + timeRangeText(result.range))
                .accessibilityIdentifier("localAnalysisOutcome")
            Spacer(minLength: 4)
            if let category = categories.first, categories.count == 1 {
                Button("查看\(category.title)") { onView(category) }
                    .accessibilityIdentifier("viewAnalysisResults")
            } else if categories.count > 1 {
                Menu("查看结果") {
                    ForEach(categories) { category in Button(category.title) { onView(category) } }
                }
                .fixedSize().accessibilityIdentifier("viewAnalysisResults")
            }
            Button("状态", action: onDetails)
            Button("关闭分析提示", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("关闭分析提示")
        }
        .font(.callout).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
