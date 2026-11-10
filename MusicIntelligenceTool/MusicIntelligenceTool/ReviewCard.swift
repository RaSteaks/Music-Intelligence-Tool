import SwiftUI

/// The inspector for one mark. All fields are visible at once, each drawn with its review state.
struct ReviewCard: View {
    let studio: Studio
    let song: SongRecord
    let row: Mark
    @State private var startText = ""
    @State private var endText = ""

    static let kindTitles: [String: String] = [
        "section": "段落", "lyric": "歌词", "word": "字词", "note": "注释", "chord": "和弦", "key": "调性",
        "key_region": "局部调性", "modulation": "转调", "emotion": "情绪", "insight": "解读", "loudness": "响度",
        "event": "声部活动", "tempo": "局部速度", "rhythm_summary": "节奏概况", "repetition": "重复片段",
        "melody_summary": "旋律概况", "melody_note": "旋律音符", "melody_phrase": "旋律乐句", "melody_motif": "旋律动机",
        "acoustic": "声学窗口", "beat": "拍点", "downbeat": "小节第一拍", "onset": "起音", "pitch": "音高"
    ]

    private var fieldKeys: [String] {
        ["label", "mood", "content"] + ["degree", "meter", "groove"].filter { row.fields[$0] != nil }
    }
    private func fieldTitle(_ key: String) -> String {
        switch key {
        case "label": row.kind == "lyric" ? "唱词" : "名称"
        case "mood": "听感"
        case "content": "音乐内容"
        case "degree": "和声级数候选"
        case "meter": "拍号线索"
        case "groove": "律动线索"
        default: key
        }
    }
    private var editableTimes: Bool {
        ["section", "lyric", "note", "insight", "event", "melody_note", "repetition"].contains(row.kind)
    }
    private var hasEmotionWindows: Bool {
        song.marks.contains { $0.kind == "emotion" && $0.metrics["valence"] != nil && $0.metrics["arousal"] != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if editableTimes {
                HStack {
                    TextField("起点（秒）", text: $startText).accessibilityIdentifier("rangeStart")
                    TextField("终点（秒）", text: $endText).accessibilityIdentifier("rangeEnd")
                    Button("应用") { applyTimes() }.accessibilityIdentifier("applyRange")
                }
                .controlSize(.small)
            }
            listening
            if row.analysisStale == true {
                Label("参考输入或检测边界已变化，此候选待核对；人工确认值仍保留。", systemImage: "circle.dotted")
                    .font(.caption).foregroundStyle(Tone.pencil.color)
            }
            Divider()
            let confirmed = fieldKeys.filter { row.fields[$0]?.confirmed != nil }.count
            Text("\(fieldKeys.count) 个字段中 \(confirmed) 个已确认").font(.caption).foregroundStyle(.secondary)
            ForEach(fieldKeys, id: \.self) { key in
                FieldRow(studio: studio, row: row, key: key, title: fieldTitle(key))
            }
            if row.kind == "lyric" { vocalState }
            if ["emotion", "section"].contains(row.kind), hasEmotionWindows {
                EmotionCompass(studio: studio, song: song, focus: row.start...row.end)
            }
            evidence
            metrics
            if row.kind == "section" {
                let summary = song.summary(for: row)
                if !summary.isEmpty { Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            structural
        }
        .textFieldStyle(.roundedBorder)
        .onAppear(perform: loadTimes)
        .onChange(of: row.start, loadTimes)
        .onChange(of: row.end, loadTimes)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.kindTitles[row.kind] ?? row.kind).font(.headline)
                Spacer()
                Button("循环试听", systemImage: "repeat") { loop(row.start...row.end) }
                    .controlSize(.small)
            }
            HStack(spacing: 4) {
                Text(clockText(row.start))
                Text("–").foregroundStyle(.secondary)
                Text(clockText(row.end))
            }
            .font(.callout.monospacedDigit())
        }
    }

    @ViewBuilder private var listening: some View {
        if ["repetition", "melody_motif"].contains(row.kind), let start = row.metrics["reference_start_s"], let end = row.metrics["reference_end_s"] {
            Button("循环试听参考片段") { loop(start...end) }.controlSize(.small)
        }
        if row.kind == "event", let source = row.fields["event_type"]?.value, song.stems[source] != nil {
            Button("试听对应分轨") { studio.chooseStem(source); loop(row.start...row.end) }.controlSize(.small)
        }
        if let source = row.fields["audio_source"]?.value {
            Button("试听分析音轨") { studio.chooseStem(source == "original" ? "原曲" : source); loop(row.start...row.end) }
                .controlSize(.small)
        }
    }

    private var vocalState: some View {
        HStack {
            Menu("演唱状态") {
                ForEach(["已辨认", "纯器乐", "有演唱但听不清"], id: \.self) { state in
                    Button(state) {
                        studio.edit { doc in
                            if let i = doc.marks.firstIndex(where: { $0.id == row.id }) {
                                doc.marks[i].fields["vocal_state"] = ReviewedText(confirmed: state)
                            }
                        }
                    }
                }
            }
            .fixedSize()
            if let value = row.fields["vocal_state"]?.value { Text(value).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var origins: [SuggestionOrigin] {
        var seen = Set<String>()
        return fieldKeys.compactMap { row.fields[$0]?.origin }.filter { seen.insert($0.runID).inserted }
    }

    @ViewBuilder private var evidence: some View {
        let origins = origins
        if !origins.isEmpty {
            let count = Set(origins.flatMap(\.evidenceIDs)).count
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(origins, id: \.runID) { origin in originView(origin) }
                }
                .padding(.top, 4)
            } label: {
                Text("依据  外部模型，\(count) 条证据").font(.callout)
            }
        }
    }

    private func originView(_ origin: SuggestionOrigin) -> some View {
        let context = song.cloudRuns?.first(where: { $0.id == origin.runID })?.context
        return VStack(alignment: .leading, spacing: 4) {
            Text(origin.provider + " / " + origin.model).font(.caption).textSelection(.enabled)
            Text(origin.stale ? "基于旧输入，待更新；确认前请重新试听。" : "模型候选，待人工核对。")
                .font(.caption).foregroundStyle(Tone.pencil.color)
            if !origin.uncertainty.isEmpty { Text("不确定处：" + origin.uncertainty).font(.caption) }
            ForEach(Array(Set(origin.evidenceIDs)).sorted(), id: \.self) { id in
                if let reference = context?.audioReferences?.first(where: { $0.id == id }) {
                    Text("音频依据 · \(reference.source.title) · \(clockText(reference.range.start)) — \(clockText(reference.range.end))")
                        .font(.caption)
                } else if id == "audio" {
                    Text("依据：本次发送的选区音频").font(.caption)
                } else if let snapshot = context?.items.first(where: { $0.id == id }) {
                    snapshotView(snapshot, current: song.marks.first(where: { $0.id == id }))
                } else if let current = song.marks.first(where: { $0.id == id }) {
                    // Older runs did not keep a snapshot; only the current item can be shown.
                    Button(current.label + "（" + clockText(current.start) + "）") { studio.select(current) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("定位当前条目；这次运行没有保存模型看到的原始输入")
                } else {
                    Text("证据条目已移除，且这次运行没有保存原始输入").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// What the model actually saw, kept apart from the current item, which may have moved, changed or been removed.
    private func snapshotView(_ snapshot: CloudContext.Item, current: Mark?) -> some View {
        let label = snapshot.fields["label"]
        let name = (label?.confirmed ?? label?.suggested).flatMap { $0.isEmpty ? nil : $0 } ?? (Self.kindTitles[snapshot.kind] ?? snapshot.kind)
        let moved = current.map { $0.start != snapshot.start || $0.end != snapshot.end } ?? false
        return VStack(alignment: .leading, spacing: 3) {
            Text((Self.kindTitles[snapshot.kind] ?? snapshot.kind) + " · " + name).font(.caption.weight(.medium))
                .textSelection(.enabled)
            Text(clockText(snapshot.start) + " — " + clockText(snapshot.end)).font(.caption.monospacedDigit())
            ForEach(snapshot.metrics.keys.sorted(), id: \.self) { key in
                Text(Self.metricText(key, value: snapshot.metrics[key] ?? 0)).font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let current {
                Button(moved ? "定位当前条目（时间已变化）" : "定位当前条目") { studio.select(current) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("当前条目：" + current.label + "，" + clockText(current.start) + " — " + clockText(current.end))
            } else {
                Text("当前条目已移除，以上为模型看到的输入").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) { Rectangle().fill(Tone.rule.color).frame(width: 1) }
    }

    @ViewBuilder private var metrics: some View {
        if !row.metrics.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(row.metrics.keys.sorted(), id: \.self) { key in
                        Text(Self.metricText(key, value: row.metrics[key] ?? 0)).font(.caption.monospacedDigit())
                    }
                    if row.metrics["template_similarity"] != nil || row.metrics["profile_correlation"] != nil {
                        Text("匹配分数和候选差距用于核对，不是识别准确率。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(.top, 4)
            } label: {
                Text("指标  \(row.metrics.count) 项").font(.callout)
            }
        }
    }

    @ViewBuilder private var structural: some View {
        if ["section", "lyric", "note"].contains(row.kind) {
            Divider()
            HStack {
                if row.kind == "section" || row.kind == "lyric" {
                    Button("在播放头拆分") { let t = studio.position; studio.edit { $0.split(row.id, at: t) } }
                    Button("合并下一段") { studio.edit { $0.mergeNext(row.id) } }
                }
                Spacer()
                if row.kind == "section" {
                    Button("删除分段", role: .destructive) { studio.deleteSection(row.id) }
                        .disabled(song.sections.count < 2)
                        .help("时间并入前一段；删除首段时并入后一段。至少保留一段。")
                }
                if row.kind == "note" {
                    Button("删除注释", role: .destructive) { studio.deleteMark(row.id) }
                }
            }
            .controlSize(.small)
        }
    }

    private func loop(_ range: ClosedRange<Double>) {
        studio.selection = range
        studio.seek(range.lowerBound)
        studio.loop = true
        if !studio.playing { studio.togglePlayback() }
    }
    private func loadTimes() {
        startText = String(format: "%.3f", row.start)
        endText = String(format: "%.3f", row.end)
    }
    private func applyTimes() {
        guard let a = Double(startText), let b = Double(endText),
              a >= 0, b <= song.duration, row.kind == "note" ? a <= b : a < b else {
            studio.notice = "请输入歌曲时长内的有效起止时间。"; return
        }
        studio.edit { doc in
            guard let i = doc.marks.firstIndex(where: { $0.id == row.id }) else { return }
            if row.kind == "section" {
                if let previous = doc.sections.last(where: { $0.end == row.start }), a != row.start {
                    doc.moveBoundary(left: previous.id, to: a)
                }
                if b != row.end { doc.moveBoundary(left: row.id, to: b) }
            } else {
                doc.marks[i].start = a; doc.marks[i].end = b
                doc.marks[i].startConfirmed = true; doc.marks[i].endConfirmed = true
                if row.kind == "lyric" { doc.invalidateWords(from: min(a,row.start), to: max(b,row.end)) }
            }
        }
    }

    static func metricText(_ key: String, value: Double) -> String {
        if key.hasPrefix("mean_") { return "区间均值 · " + metricText(String(key.dropFirst(5)), value: value) }
        let descriptions = [
            "integrated_lufs": ("综合响度", "LUFS"), "short_lufs": ("短时响度", "LUFS"),
            "loudness_range_lu": ("响度范围", "LU"), "true_peak_dbtp": ("真峰值", "dBTP"),
            "sample_peak_dbfs": ("采样峰值", "dBFS"), "rms_dbfs": ("RMS", "dBFS"),
            "crest_db": ("峰均比", "dB"), "stereo_correlation": ("声道相关系数", ""),
            "channels": ("声道数", ""), "sample_rate_hz": ("原始采样率", "Hz"),
            "measured_duration_s": ("测量时长", "秒"), "template_similarity": ("和弦模板匹配", ""),
            "template_margin": ("和弦候选差距", ""), "profile_correlation": ("调性轮廓相关", ""),
            "profile_margin": ("调性候选差距", ""), "centroid_hz": ("频谱重心", "Hz"),
            "onsets_per_s": ("起音密度", "次/秒"), "valence": ("效价", ""), "arousal": ("唤醒度", ""),
            "threshold_dbfs": ("活动门限", "dBFS"), "resolution_s": ("检测时间分辨率", "秒"), "bridged_gap_s": ("合并间隙上限", "秒"),
            "tempo_bpm": ("参考速度", "BPM"), "half_tempo_bpm": ("半速候选", "BPM"), "double_tempo_bpm": ("倍速候选", "BPM"),
            "beat_interval_mad": ("拍间相对变异", ""), "beats_per_bar": ("每小节检测拍数", ""), "meter_support": ("拍号线索支持度", ""),
            "swing_ratio": ("长短拍比例", ""), "offbeat_onset_fraction": ("离拍起音比例", ""),
            "frequency_hz": ("音高频率", "Hz"), "midi_pitch": ("连续音高", "MIDI"), "midi_note": ("音符候选", "MIDI"),
            "pitch_low_midi": ("音域下界", "MIDI"), "pitch_high_midi": ("音域上界", "MIDI"), "pitch_span_semitones": ("检测跨度", "半音"),
            "pitched_fraction": ("检测到音高的时长占比", ""), "pitch_salience": ("旋律显著度（非准确率）", ""), "vibrato_hz": ("音高调制线索", "Hz"),
            "similarity": ("片段相似度（非准确率）", ""), "transpose_semitones": ("移调候选", "半音"), "duration_ratio": ("片段时长比", ""),
            "reference_start_s": ("参考片段起点", "秒"), "reference_end_s": ("参考片段终点", "秒")
        ]
        if key.hasPrefix("coverage_") {
            let metric = String(key.dropFirst(9))
            return (descriptions[metric]?.0 ?? metric) + String(format: " 有效覆盖 %.1f%%", value * 100)
        }
        for suffix in ["_activity_fraction", "_coverage"] where key.hasSuffix(suffix) {
            let source = String(key.dropLast(suffix.count))
            let title = CloudAudioSource(rawValue: source)?.title ?? (source == "silence" ? "近静音" : source)
            return title + (suffix == "_coverage" ? " 检测覆盖" : " 活动占比") + String(format: " %.1f%%", value * 100)
        }
        if key == "full_scale_fraction" { return String(format: "满幅采样占比  %.4f%%", value * 100) }
        let description = descriptions[key] ?? (key, "")
        return description.0 + "  " + String(format: "%.2f", value) + " " + description.1
    }
}

/// One reviewable field: adopt, edit in place, reject, or attach a hint.
private struct FieldRow: View {
    private enum Focus { case value, hint }
    let studio: Studio
    let row: Mark
    let key: String
    let title: String
    @State private var editing = false
    @State private var draft = ""
    @State private var editingHint = false
    @State private var hintDraft = ""
    @FocusState private var focus: Focus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var field: ReviewedText { row.fields[key] ?? ReviewedText() }

    var body: some View {
        let state = field.provenance
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(state.title).font(.caption2).foregroundStyle(state == .confirmed ? Tone.human.color : Tone.pencil.color)
            }
            if editing {
                TextField("校对后的内容", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focus, equals: .value)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onAppear { focus = .value }
                HStack {
                    Button("确认", action: commit).buttonStyle(.borderedProminent)
                    Button("取消") { editing = false }
                }
                .controlSize(.small)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Group {
                        if state == .confirmed {
                            Seal(size: 7).transition(.scale(scale: 1.15).combined(with: .opacity))
                        } else {
                            ProvenanceGlyph(state: state)
                        }
                    }
                    .frame(width: 10)
                    value(state)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title + "，" + state.title)
                .accessibilityValue(field.confirmed ?? field.suggested ?? "")
                if let suggested = field.suggested, let confirmed = field.confirmed, suggested != confirmed {
                    Text("原建议 · " + suggested).font(.caption).foregroundStyle(Tone.pencil.color)
                        .lineLimit(2).textSelection(.enabled)
                }
                actions
            }
            hint
        }
    }

    @ViewBuilder private func value(_ state: Provenance) -> some View {
        switch state {
        case .confirmed:
            Text(field.confirmed ?? "").fontWeight(.semibold).foregroundStyle(Tone.ink.color).textSelection(.enabled)
        case .suggested:
            Text(field.suggested ?? "").foregroundStyle(Tone.pencil.color).textSelection(.enabled)
        case .rejected:
            Text(field.suggested ?? "").strikethrough().foregroundStyle(Tone.pencil.color).textSelection(.enabled)
        case .stale:
            Text(field.suggested ?? "").foregroundStyle(Tone.pencil.color).opacity(0.55).textSelection(.enabled)
        case .cleared:
            Text("已清空").italic().foregroundStyle(.secondary)
        case .empty:
            Text("未填写").foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if field.suggested != nil, field.confirmed == nil, field.suggestionAvailable {
                Button("采纳") { confirm(field.suggested ?? "") }
                    .help("把模型建议写成确认值")
            }
            Button(field.confirmed == nil && field.suggested == nil ? "填写" : "修改") {
                draft = field.confirmed ?? field.suggested ?? ""
                editing = true
            }
            if field.suggested != nil, field.confirmed == nil {
                Button(field.rejected == true ? "恢复建议" : "拒绝") { toggleRejected() }
            }
            if !field.hasHint && !editingHint {
                Button("加提示") { hintDraft = ""; editingHint = true }
            }
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    @ViewBuilder private var hint: some View {
        if editingHint {
            HStack(alignment: .top, spacing: 6) {
                Rectangle().fill(Tone.human.color).frame(width: 2)
                TextField("给分析的提示", text: $hintDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focus, equals: .hint)
                    .onSubmit(saveHint)
                    .onExitCommand { editingHint = false }
                    .onAppear { focus = .hint }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("保存提示", action: saveHint)
                Button("取消") { editingHint = false }
            }
            .controlSize(.small)
        } else if let text = field.hint, !text.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Rectangle().fill(Tone.human.color).frame(width: 2)
                Text(text).font(.callout).textSelection(.enabled)
                Spacer(minLength: 4)
                Button("编辑") { hintDraft = text; editingHint = true }.buttonStyle(.link).font(.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("提示：" + text)
        }
    }

    private func confirm(_ value: String) {
        studio.edit { doc in
            guard let i = doc.marks.firstIndex(where: { $0.id == row.id }) else { return }
            doc.marks[i].fields[key, default: ReviewedText()].confirmed = value
            if row.kind == "lyric" && key == "label" { doc.invalidateWords(from: row.start, to: row.end) }
        }
    }
    private func commit() {
        confirm(draft)
        editing = false
    }
    private func toggleRejected() {
        let rejected = field.rejected == true
        studio.edit { doc in
            if let i = doc.marks.firstIndex(where: { $0.id == row.id }) {
                doc.marks[i].fields[key, default: ReviewedText()].rejected = !rejected
            }
        }
    }
    private func saveHint() {
        let text = hintDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        studio.edit { doc in
            if let i = doc.marks.firstIndex(where: { $0.id == row.id }) {
                doc.marks[i].fields[key, default: ReviewedText()].hint = text.isEmpty ? nil : text
            }
        }
        editingHint = false
    }
}

/// Valence (x) against arousal (y), both 1–9 as Music2Emo reports them. Windows are joined in time order;
/// those inside the selected range are solid and the window under the playhead is ringed.
struct EmotionCompass: View {
    let studio: Studio
    let song: SongRecord
    let focus: ClosedRange<Double>

    var body: some View {
        let windows = song.marks.filter {
            $0.kind == "emotion" && $0.analysisStale != true && $0.metrics["valence"] != nil && $0.metrics["arousal"] != nil
        }.sorted { $0.start < $1.start }
        let cursor = studio.cursor
        VStack(alignment: .leading, spacing: 4) {
            Text("情绪罗盘").font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                let plot = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                func point(_ row: Mark) -> CGPoint {
                    let v = (min(9, max(1, row.metrics["valence"] ?? 5)) - 1) / 8
                    let a = (min(9, max(1, row.metrics["arousal"] ?? 5)) - 1) / 8
                    return CGPoint(x: plot.minX + plot.width * v, y: plot.maxY - plot.height * a)
                }
                context.stroke(Path(roundedRect: plot, cornerRadius: 4), with: .color(Tone.rule.color))
                var cross = Path()
                cross.move(to: CGPoint(x: plot.midX, y: plot.minY)); cross.addLine(to: CGPoint(x: plot.midX, y: plot.maxY))
                cross.move(to: CGPoint(x: plot.minX, y: plot.midY)); cross.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
                context.stroke(cross, with: .color(Tone.rule.color), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.draw(Text("激动").font(.caption2).foregroundStyle(Tone.pencil.color),
                             at: CGPoint(x: plot.midX + 4, y: plot.minY + 3), anchor: .topLeading)
                context.draw(Text("平静").font(.caption2).foregroundStyle(Tone.pencil.color),
                             at: CGPoint(x: plot.midX + 4, y: plot.maxY - 3), anchor: .bottomLeading)
                var trail = Path()
                for (n, row) in windows.enumerated() {
                    if n == 0 { trail.move(to: point(row)) } else { trail.addLine(to: point(row)) }
                }
                context.stroke(trail, with: .color(Tone.machine.color.opacity(0.35)), lineWidth: 1)
                for row in windows {
                    let p = point(row)
                    let inside = row.end > focus.lowerBound && row.start < focus.upperBound
                    let r: CGFloat = inside ? 3 : 2
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(Tone.machine.color.opacity(inside ? 1 : 0.35)))
                    if row.start <= cursor && cursor < row.end {
                        context.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                                       with: .color(Tone.ink.color), lineWidth: 1.5)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 220)
            HStack {
                Text("负向"); Spacer(); Text("效价"); Spacer(); Text("正向")
            }
            .font(.caption2).foregroundStyle(Tone.pencil.color)
            .frame(maxWidth: 220)
        }
        .accessibilityElement()
        .accessibilityLabel("情绪罗盘")
        .accessibilityValue(summary(windows))
    }

    private func summary(_ windows: [Mark]) -> String {
        let inside = windows.filter { $0.end > focus.lowerBound && $0.start < focus.upperBound }
        guard !inside.isEmpty else { return "选区内没有情绪窗口" }
        let v = inside.compactMap { $0.metrics["valence"] }.reduce(0, +) / Double(inside.count)
        let a = inside.compactMap { $0.metrics["arousal"] }.reduce(0, +) / Double(inside.count)
        return String(format: "选区内 %d 个窗口，平均效价 %.1f，平均唤醒度 %.1f（1 到 9）", inside.count, v, a)
    }
}
