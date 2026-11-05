<p align="center">
  <img src="MusicIntelligenceTool/MusicIntelligenceTool/Assets.xcassets/AppIcon.appiconset/mac-256.png" width="128" alt="Music Intelligence Tool 图标">
</p>

<h1 align="center">Music Intelligence Tool</h1>

<p align="center">
  在 Mac 上本地运行的音乐分析与标注工具。<br>
  在波形上试听、分段、校对歌词与情绪，再把带时间和来源的结果导出为 JSON，或通过 MCP 交给 agent。
</p>

<p align="center">
  <a href="#功能">功能</a> ·
  <a href="#使用">使用</a> ·
  <a href="#license">License</a>
</p>

---

## 功能

### 波形编辑

- **试听与定位**：在波形顶部的时间尺上点击或拖动，可以实时移动播放头，不改变出入点；点击波形也能跳到对应时刻。按空格播放或暂停。开启「循环」后，会反复播放当前选区或选中的条目。
- **缩放与导航**：时间轴最多可放大 24 倍。放大后拖动下方滚动条，会弹出全曲缩略图，显示当前所在范围。
- **出入点**：按 `I`、`O` 在播放头处标记入点和出点。没有入点时直接按 `O`，默认从歌曲开头开始；向后连续按 `O`，以上一次出点作为下一段入点。按 `I` 可以指定新的起点，拖动“入／出”标记可以微调当前选区。也可以直接在波形上拖出一段选区。
- **段落编辑**：拖动两段之间的共享边界，相邻两段会同步更新。可以在出入点或播放头处切分，也可以合并、删除段落；删除的时间会并入相邻段落，整首歌始终至少保留一段。
- **拍点吸附**：编辑选区或边界时自动吸附到最近的拍点，按住 `⌥` 可以临时关闭。时间尺上的播放头定位保持连续，不吸附。
- **叠加轨道**：在「显示轨道」里按需打开段落、拍点、小节第一拍、起音、声学能量、情绪走势、歌词、字词、和弦、注释。
- **分轨试听**：结构分析完成后，可以在原曲和人声、鼓、贝斯、其他伴奏四轨之间切换，播放位置保持不变。

### 自动分析

在工具栏「分析」里，可以一次运行整首歌曲的分析，也可以只对当前选区单独运行某个模块。分析在后台进行，期间可以继续播放和编辑。

| 模块 | 输出 | 实现 |
|---|---|---|
| 结构 · 节拍 · 分轨 | 段落与候选名称、逐拍和小节第一拍、局部速度、全曲 BPM、四条分离音轨 | All-In-One（Apple Silicon 移植） |
| 声学特征 | 每秒短时响度、RMS、低中高频占比、频谱重心、起音点与起音密度 | FFmpeg EBU R128、librosa |
| 调性与和弦 | 全曲调性、逐秒的大小三和弦候选，不可靠时留空 | librosa Chroma + 模板匹配 |
| 逐句歌词 | 逐句歌词和起止时间，有人声轨时优先使用人声轨 | Whisper |
| 情绪标签与走势 | 按段落切成不超过 30 秒的窗口，给出情绪标签、效价和唤醒度 | Music2Emo |
| 歌词字词对齐 | 按校对后的歌词文本生成逐字或逐词时间，支持中英文 | WhisperX |

> [!NOTE]
> 「分析整首歌曲」包含前五个模块。「歌词字词对齐」需要先有歌词，所以要单独运行。

- **不覆盖人工修改**：后台结果只替换本模块在分析区间内的内容，人工确认过的边界和字段都会保留。如果分析期间段落边界或歌词被改过，对应模块会标为「待更新」。
- **状态可查**：底部栏显示当前任务，可以随时取消。在「分析状态与 MCP」里可以查看每个模块的状态：完成、无可靠结果、待更新、失败或已取消。

### 人工校对

- **字段分别处理**：每个条目的名称或唱词、听感、音乐内容都单独显示模型建议，可以分别确认、修改或清空。
- **提示和确认分开**：「给分析的提示」用于记下还要核对的线索，例如"这里好像已经进鼓"；「确认此字段」才会写入确认值。两者分别保存，不会混在一起。
- **精确调整**：可以直接输入起止秒数，也可以一键「循环试听选段」，用耳朵判断落点。
- **歌词**：支持拆句、合句、拖动句首句尾，还可以标记演唱状态：已辨认、纯器乐、有演唱但听不清。
- **注释**：可以标在某一时刻，也可以标一段范围，范围可以跨段落。
- **段落摘要**：根据响度变化、情绪和人工填写的内容，为每个段落生成一句简短说明。
- **撤销与保存**：按 `⌘Z` 撤销。每次修改都会自动保存，重新打开同一首歌时会恢复上次的结果。

### 交给 agent

- **导出 JSON**：保存当前歌曲完整的分析记录，包括模型建议、人工确认值、提示和数据来源。
- **发送给 agent**：点击「保存提示」右侧的剪贴板图标，会复制当前歌曲已保存的分段、注释、校对内容，以及现成的 MCP 查询指令，可以直接粘贴到对话里。
- **MCP 服务**：App 启动时会在本机 `http://127.0.0.1:18765/mcp` 提供服务，只监听本机。端口可以在 **设置 → MCP 服务** 中修改。

| 工具 | 用途 |
|---|---|
| `analyze_music(path)` | 在 App 中打开本地音频，补跑尚未完成的分析，返回 `track_id` 和状态 |
| `get_music_overview(track_id)` | 读取保存修订号、模块状态、时长、BPM、调性、段落和情绪窗口 |
| `get_music_timeline(track_id, start_s, end_s, types, confirmed_only)` | 按时间区间和类型读取拍点、歌词、和弦、情绪、事件或注释，可以只取人工确认的内容 |

返回值的规则和界面一致：有人工确认就返回确认值，来源标为 `user`；没有就返回模型建议，并标明是哪个模块给出的。人工提示单独列在 `hints` 中。

## 使用

### 环境要求

| 项目 | 要求 |
|---|---|
| 设备与系统 | Apple Silicon Mac，macOS 15.8 或更高版本 |
| 开发工具 | Xcode 26 |
| 分析环境 | FFmpeg（`brew install ffmpeg`）、Python 3.10 和 3.12 |

### 安装分析环境

在仓库根目录运行安装脚本，按需要选择安装范围：

```sh
./script/setup.sh all
```

| 参数 | 安装内容 |
|---|---|
| 不带参数 | 基础环境：声学特征、调性与和弦、逐句歌词和 MCP 服务 |
| `models` | 基础环境，加上结构分析和情绪识别 |
| `align` | 基础环境，加上歌词字词对齐 |
| `all` | 全部 |

在 **设置（`⌘,`）→ 分析环境** 查看 FFmpeg、Python 依赖和模型缓存，按功能下载缺少的权重。首次准备 Demucs 时可能需要安装转换依赖。Python 不在默认路径时，可用 `PYTHON` 和 `PYTHON_MODERN` 指定 3.10 和 3.12 的解释器。

环境检测结果会按运行目录保存。首次没有记录时自动检查一次，之后切换页面或重启 App 都会复用结果，点击「重新检查」才会重新全量检测；下载模型后只更新并保存对应功能的状态。切换运行目录时会读取该目录的记录，没有记录则首次检查。

### 启动 App

1. 用 Xcode 打开 `MusicIntelligenceTool/MusicIntelligenceTool.xcodeproj`，运行目标选择 **My Mac**，按 `⌘R` 运行。也可以在终端运行 `./script/build_and_run.sh`。
2. 点击工具栏中间的「设置」（或按 `⌘,`）切到设置页，在 **分析环境** 中点「运行目录」旁的「选择…」，选中本仓库根目录。从 Xcode 运行时，如果仓库里已经有 `.venv`，App 会自动使用它。设置完成后，点「工作区」回到编辑界面。
3. 点击「打开音频…」导入 WAV、MP3、FLAC 或 M4A 文件。想先熟悉操作，可以点「试听内置练习曲」，不安装模型也能编辑。

如果音频或运行目录位于「桌面」，macOS 首次询问访问权限时请点「允许」。若此前拒绝，可在 **系统设置 → 隐私与安全性 → 文件与文件夹 → MusicIntelligenceTool → 桌面文件夹** 中开启。Xcode 的 Debug 和 Release 配置均已声明桌面访问用途。

### 基本流程

1. **试听并手动分段**：在波形上找到段落起点，按 `I`、`O` 标出范围后点「分段」，再在右侧校对面板里填写段名和听感。
2. **运行分析**：在「分析」中选择「分析整首歌曲」，或者只对选区运行某个模块。
3. **校对结果**：拖动边界修正段落，在校对面板里确认、修改模型建议，或者留下待核对的提示。
4. **交给 agent**：导出 JSON，或者让本机 agent 连接 MCP 读取最新结果。

### 快捷键

| 操作 | 快捷键 |
|---|---|
| 播放 / 暂停 | `Space` |
| 标记入点 / 出点 | `I` / `O`，可以在设置（`⌘,`）中更改 |
| 拖动时临时关闭拍点吸附 | 按住 `⌥` |
| 撤销 | `⌘Z` |
| 打开音频 | `⌘O` |
| 删除选中的段落 | `Delete` |

### 连接 agent

App 运行时，MCP 服务会自动启动。把本机 agent 连接到 `http://127.0.0.1:18765/mcp`（Streamable HTTP）即可。以 Claude Code 为例：

```sh
claude mcp add --transport http music-intelligence http://127.0.0.1:18765/mcp
```

如果端口被其他程序占用，**设置 → MCP 服务** 会提示，在那里换一个端口即可，服务会自动重启。换端口后，agent 中登记的地址也要同步更新。

连接后，可以先粘贴「发送给 agent」复制的内容，agent 会按里面的指令查询这首歌的最新记录。App 退出后，导出的 JSON 仍然可以单独读取。

<details>
<summary>可选的环境变量</summary>

| 变量 | 作用 | 默认值 |
|---|---|---|
| `MIT_MCP_PORT` | MCP 服务端口，优先于设置页中的端口 | `18765` |
| `MIT_WHISPER_MODEL` | 逐句歌词使用的 Whisper 模型 | `base` |
| `MIT_LYRIC_LANGUAGE` | 字词对齐的语言 | 根据歌词自动判断中文或英文 |
| `MIT_LIBRARY` | 歌曲记录的保存目录 | `~/Library/Application Support/MusicIntelligenceTool/Tracks` |
| `MIT_RUNTIME` | Python 运行环境目录，优先级高于界面中的选择 | — |

</details>

## License

本项目代码采用 [GNU AGPLv3](LICENSE)。第三方代码和模型权重遵循各自许可；Music2Emo 的[发布模型](https://huggingface.co/amaai-lab/music2emo)和 [MERT 基础权重](https://huggingface.co/m-a-p/MERT-v1-95M)分别标注 Apache-2.0 和 CC BY-NC 4.0。

| 用途 | 参考仓库 | 参考论文 |
|---|---|---|
| 结构与节拍 | [All-In-One](https://github.com/mir-aidj/all-in-one)、[Apple Silicon 移植](https://github.com/ssmall256/all-in-one-mlx) | [All-In-One Metrical and Functional Structure Analysis](https://arxiv.org/abs/2307.16425) |
| 声部分离 | [Demucs](https://github.com/facebookresearch/demucs) | [Hybrid Transformers for Music Source Separation](https://arxiv.org/abs/2211.08553) |
| 歌词与对齐 | [Whisper](https://github.com/openai/whisper)、[WhisperX](https://github.com/m-bain/whisperX) | [Whisper](https://arxiv.org/abs/2212.04356)、[WhisperX](https://arxiv.org/abs/2303.00747) |
| 情绪与走势 | [Music2Emo](https://github.com/AMAAI-Lab/Music2Emotion)、[MERT](https://github.com/yizhilll/MERT) | [Music2Emo](https://arxiv.org/abs/2502.03979)、[MERT](https://arxiv.org/abs/2306.00107) |
| 声学、和声与协议 | [FFmpeg](https://github.com/FFmpeg/FFmpeg)、[librosa](https://github.com/librosa/librosa)、[MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk) | [librosa: Audio and Music Signal Analysis in Python](https://doi.org/10.25080/Majora-7b98e3ed-003) |
