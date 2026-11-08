import SwiftUI

/// Track names sit outside the canvas so the canvas keeps a direct time-to-x mapping.
/// Rows use the canvas's own layout so names line up with what is drawn.
struct TrackGutter: View {
    let studio: Studio
    let record: SongRecord
    @Binding var bars: Bool

    static let lanes = [("section","段落"),("beat","拍点"),("downbeat","小节第一拍"),("onset","起音"),
                        ("acoustic","声学能量"),("emotion","情绪走势"),("lyric","歌词"),("word","字词"),
                        ("chord","和弦"),("note","注释"),("event","声部活动与停顿"),("insight","选中解读范围"),
                        ("tempo","局部速度"),("repetition","重复片段"),("pitch","旋律音高")]

    private var hasBars: Bool {
        record.marks.lazy.filter { $0.kind == "downbeat" && $0.analysisStale != true }.prefix(2).count > 1
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = CanvasLayout(record: record, visible: studio.visibleKinds, hidden: studio.hiddenLanes,
                                      selected: studio.selected, height: geometry.size.height, scroll: studio.laneScroll)
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.lanes.enumerated()), id: \.element) { index, key in
                    if index % 2 == 0 && layout.visibleLanes.contains(index) {
                        Tone.stripe.color
                            .frame(height: CanvasLayout.laneStep)
                            .offset(y: layout.laneTop(index) - 1)
                    }
                }
                Button(bars && hasBars ? "小节" : "时间") { bars.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Tone.pencil.color)
                    .disabled(!hasBars)
                    .help(hasBars ? "切换时间尺：时间或小节" : "结构分析得到小节第一拍后，可以按小节显示时间尺")
                    .accessibilityLabel("时间尺单位")
                    .accessibilityValue(bars && hasBars ? "小节" : "时间")
                    .frame(width: CanvasLayout.gutterWidth - 10, height: CanvasLayout.rulerHeight, alignment: .leading)
                    .padding(.leading, 10)
                Rectangle().fill(Tone.rule.color).frame(height: 1)
                    .offset(y: CanvasLayout.rulerHeight - 1)
                if studio.visibleKinds.contains("section") {
                    name("段落", kind: "section")
                        .frame(height: CanvasLayout.bandBottom - CanvasLayout.bandTop)
                        .offset(y: CanvasLayout.bandTop)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Text("波形").font(.caption).foregroundStyle(Tone.pencil.color)
                        Spacer(minLength: 0)
                        if layout.overflows { scrollButtons(layout) }
                    }
                    .padding(.trailing, 4)
                    Menu {
                        ForEach(Self.lanes, id: \.0) { kind, title in
                            Toggle(title, isOn: Binding(get: { studio.visibleKinds.contains(kind) }, set: {
                                if $0 {
                                    studio.visibleKinds.insert(kind)
                                    if kind == "event" { studio.hiddenLanes.removeAll() }
                                } else { studio.visibleKinds.remove(kind) }
                            }))
                            if kind == "event" && studio.visibleKinds.contains("event") {
                                ForEach(eventLanes, id: \.self) { lane in
                                    Toggle("　" + (CanvasLayout.titles[lane] ?? lane), isOn: Binding(
                                        get: { !studio.hiddenLanes.contains(lane) },
                                        set: { if $0 { studio.hiddenLanes.remove(lane) } else { hide(lane) } }))
                                }
                            }
                        }
                    } label: {
                        Label("轨道", systemImage: "slider.horizontal.3").font(.caption2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Tone.pencil.color)
                    .accessibilityLabel("显示轨道")
                    .help("选择要显示的轨道")
                }
                .padding(.leading, 10)
                .frame(height: max(30, layout.waveBottom - CanvasLayout.waveTop))
                .offset(y: CanvasLayout.waveTop)
                ForEach(Array(layout.lanes.enumerated()), id: \.element) { index, key in
                    if layout.visibleLanes.contains(index) {
                        name(CanvasLayout.titles[key] ?? key, kind: key)
                            .frame(height: CanvasLayout.laneHeight)
                            .offset(y: layout.laneTop(index))
                    }
                }
            }
            .frame(width: CanvasLayout.gutterWidth, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(width: CanvasLayout.gutterWidth)
        .background(Tone.paper.color)
        .overlay(alignment: .trailing) { Rectangle().fill(Tone.rule.color).frame(width: 1) }
        .clipped()
    }

    /// Event types present in this record, in lane order.
    private var eventLanes: [String] {
        let types = Set(record.marks.filter { $0.kind == "event" }.compactMap { $0.fields["event_type"]?.value })
        return ["silence", "vocals", "drums", "bass"].filter(types.contains).map { "event:" + $0 }
    }

    /// Hides one event sub-lane. Hiding the last one turns the event track off, so the menu stays truthful.
    private func hide(_ lane: String) {
        studio.hiddenLanes.insert(lane)
        if eventLanes.allSatisfy(studio.hiddenLanes.contains) {
            studio.visibleKinds.remove("event")
            studio.hiddenLanes.removeAll()
        }
    }

    private func scrollButtons(_ layout: CanvasLayout) -> some View {
        HStack(spacing: 0) {
            Button("上移轨道", systemImage: "chevron.up") { studio.laneScroll = layout.firstLane - 1 }
                .disabled(!layout.canScrollUp)
            Button("下移轨道", systemImage: "chevron.down") { studio.laneScroll = layout.firstLane + 1 }
                .disabled(!layout.canScrollDown)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Tone.pencil.color)
        .help("显示第 \(layout.firstLane + 1)–\(layout.firstLane + layout.visibleCount) 条，共 \(layout.lanes.count) 条数据轨；也可以在轨道区域滚动")
    }

    /// Clicking a name hides exactly the track it names; the track menu brings it back.
    /// An event lane key ("event:vocals") hides only that sub-lane.
    private func name(_ title: String, kind: String) -> some View {
        Button(title) {
            if kind.hasPrefix("event:") { hide(kind) } else { studio.visibleKinds.remove(kind) }
        }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Tone.pencil.color)
            .lineLimit(1)
            .help("点击隐藏「\(title)」轨道")
            .frame(width: CanvasLayout.gutterWidth - 10, alignment: .leading)
            .padding(.leading, 10)
    }
}
