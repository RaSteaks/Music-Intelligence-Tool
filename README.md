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
| 声学特征 | 每秒短时响度、RMS、频段占比、频谱重心与起音；区间综合响度、响度范围、真峰值、峰均比和声道相关性 | FFmpeg EBU R128、librosa |
| 调性与和弦 | 全曲与局部调性、逐拍和弦、七和弦／挂留／减增／转位候选、和声级数及调性变化窗口 | librosa Chroma、模板匹配与时间连续性解码 |
| 节奏与律动 | 多拍速度统计、局部速度、半速／倍速、拍号候选和长短拍线索 | 优先复用 All-In-One 拍点；librosa 动态节拍补充 |
| 重复结构与段落关系 | 重复段落、移调与变速片段候选，关联参考片段并支持交替试听 | Chroma／MFCC 动态时间对齐 |
| 主导旋律与音域 | 音高轨迹、音符及乐句候选、相似旋律动机、检测音域和音高调制线索；有人声轨时优先分析人声 | Essentia Melodia，独立运行环境 |
| 逐句歌词 | 逐句歌词和起止时间，有人声轨时优先使用人声轨 | Whisper |
| 情绪标签与走势 | 按段落切成不超过 30 秒的窗口，给出情绪标签、效价和唤醒度 | Music2Emo |
| 声部活动与停顿 | 人声、鼓、贝斯的分轨活动及近静音候选，附检测门限、时间分辨率、覆盖区间和缺失警告 | 原始声道 RMS、滞回与短间隙合并 |
| 歌词字词对齐 | 按校对后的歌词文本生成逐字或逐词时间，支持中英文 | WhisperX |

> [!NOTE]
> 「分析整首歌曲」包含前九个模块。「歌词字词对齐」需要先有歌词，所以要单独运行。结构与重复关系按全曲分析，其他模块可以使用选区。

- **不覆盖人工修改**：后台结果只替换本模块在分析区间内的内容，人工确认过的边界和字段都会保留。如果分析期间段落边界或歌词被改过，对应模块会标为「待更新」。
- **状态可查**：底部栏显示当前任务，可以随时取消。在「分析状态与 MCP」里可以查看每个模块的状态：完成、无可靠结果、待更新、失败或已取消。

### 外部模型分析

可以在 **设置 → 外部模型** 配置 **OpenAI API／兼容服务** 或 **OpenRouter**，保存多个连接，并为文字解读和音频理解选择不同模型。密钥保存在 macOS 钥匙串中，连接配置独立于歌曲记录。现有「分析整首歌曲」和 MCP 的 `analyze_music` 继续只运行本地模块。

1. 新建连接，填写 Base URL、API Key 和模型 ID。可点击「获取模型」选择模型，也可以手动填写。更换 API 地址的协议、主机或端口时，需为新地址重新输入密钥。OpenRouter 默认使用 Responses，OpenAI 默认使用 Chat Completions。兼容服务可按其实际支持选择接口和输出参数。
2. 按需运行文字或音频请求测试。测试会使用服务额度；音频测试只发送内置的一秒合成音。模型目录声明的音频支持与实际请求验证分别记录，修改地址或模型后需重新检查。
3. 回到工作区，选中段落或拖出选区，点击「外部模型分析」。**解读已有结果**仅发送相关记录、歌词和人工提示；**分析选区音频**可以勾选原曲及已存在的分轨。开始前核对接收方、模型、音轨和原曲起止秒数；时长限制按所有发送音轨的总时长计算。
4. 在「解读」列表中查看候选、来源、不确定处和输入证据快照，循环试听后分别确认、修改或拒绝字段。修改相关输入后，旧建议标为待更新；人工确认继续保留。

相同输入和配置可以复用有效结果；启用「重新调用模型」才会绕过缓存。应用不自动切换模型或接入渠道；OpenRouter 的上游服务商可单独限定。取消会停止后续处理，但已经提交的远端请求可能仍产生费用。具体用量和任务状态可在「分析状态与 MCP」查看。

严格 JSON Schema 只适用于支持该能力的模型；其他模型可选择提示词 JSON，由应用检查结构、时间范围和证据引用。请求测试通过仅代表接口与输出格式可用，不代表音乐判断准确。未配置外部模型时，本地功能继续独立使用。

还可以在同一入口选择：

- **核对提示**：填写需要核查的问题，也可沿用当前条目的人工提示；按需附带原曲或人声、鼓、贝斯轨。问题本身始终作为线索保存。
- **比较两个段落**：只发送所选两段的记录、覆盖率明确的声学均值和已有有效解读，不发送中间段落或音频。
- **汇总已有解读**：汇总选区内的有效结果，并标明尚未完成分段分析的范围。
- **整曲分段分析并汇总**：按段落边界和最长窗口规划，预览每段范围、音轨、分段模型和最终文字汇总模型；最多 50 次请求。任何片段失败、取消或相关输入变化都会停止后续调用，已完成片段保留；重新运行会复用仍有效的缓存。
- **同一输入双模型对照**：选择两个不同模型或渠道，分别使用相同范围、音轨和记录独立分析，最多两次请求。结果在「模型对照」中并排显示，可逐条进入校对；不会自动调用第三个模型裁判，也不把模型一致视为事实。
- **主唱与和声层次核对**：在「核对提示」中使用对应预设，优先选择已有的人声轨；由所选音频模型提出层次与活动区间候选，并保留听不清、无法区分的部分。

「事件」列表提供声部活动和停顿候选，可定位、调整时间、校对字段或试听对应分轨。能量活动不等于准确乐器识别，分轨串音可能造成误报。缺少分轨表示未分析该声部，不表示音乐中没有该声部；警告可在「分析状态与 MCP」查看。更新分轨后旧候选标为待核对，人工确认继续保留。

「节奏与律动」「重复关系」「旋律与音域」可从标注列表菜单查看。在显示轨道中开启局部速度、重复片段或旋律音高；重复候选支持循环试听参考片段。旋律寻找范围为 65–2093 Hz，原混音可能误选伴奏或低音，检测音域不代表歌手完整音域。乐句按旋律空隙给出候选，短音符或密集多声部可能漏检；当前不提供完整乐谱或 MIDI 导出。拍号保留多个可能解释，不仅凭拍点数量确定记谱分母。

### 人工校对

- **字段分别处理**：每个条目的名称或唱词、听感、音乐内容都单独显示模型建议，可以分别确认、修改或清空。
- **提示和确认分开**：「给分析的提示」用于记下还要核对的线索，例如"这里好像已经进鼓"；「确认此字段」才会写入确认值。两者分别保存，不会混在一起。
- **精确调整**：可以直接输入起止秒数，也可以一键「循环试听选段」，用耳朵判断落点。
- **歌词**：支持拆句、合句、拖动句首句尾，还可以标记演唱状态：已辨认、纯器乐、有演唱但听不清。
- **注释**：可以标在某一时刻，也可以标一段范围，范围可以跨段落。
- **段落摘要**：按时间覆盖汇总主要情绪，比较段首与段尾的响度、起音密度和唤醒度，再结合人工内容生成简短说明。明确清空的人工听感不会被自动建议补回。
- **响度统计**：在「响度」列表查看本次分析区间的测量。短时响度不足三秒的启动窗口留空；峰均比与响度范围分别显示。和弦与调性分数用于核对，不是识别准确率。
- **撤销与保存**：按 `⌘Z` 撤销。每次修改都会自动保存，重新打开同一首歌时会恢复上次的结果。

### 交给 agent

- **导出 JSON**：保存当前歌曲完整的分析记录，包括模型建议、人工确认值、提示和数据来源。
- **发送给 agent**：点击「保存提示」右侧的纸飞机图标，通过本机 MCP Channel 通知 Claude Code 读取当前歌曲的完整分析记录。保留模型建议、人工确认、提示、声学指标、模块状态和分轨路径；点击时的修订会固定下来，后续编辑不影响这次交接。首次使用需按下文配置 Claude Code Channel。
- **复制交接文本**：旁边的剪贴板图标会复制完整分析记录及 MCP 查询指令，供其他 agent 或未启用 Channel 时手动粘贴。
- **MCP 服务**：App 启动时会在本机 `http://127.0.0.1:18765/mcp` 提供服务，只监听本机。端口可以在 **设置 → MCP 服务** 中修改。

| 工具 | 用途 |
|---|---|
| `analyze_music(path)` | 在 App 中打开本地音频，补跑尚未完成的分析，返回 `track_id` 和状态 |
| `get_music_overview(track_id)` | 读取保存修订号、模块状态、时长、BPM、调性、段落和情绪窗口 |
| `get_music_record(track_id)` | 原样读取完整保存记录，同时保留模型建议、人工确认、提示、指标、原曲和分轨路径 |
| `get_music_timeline(track_id, start_s, end_s, types, confirmed_only)` | 按时间区间和类型读取拍点、歌词、和弦、情绪、事件或注释，可以只取人工确认的内容 |

概览和时间轴查询的规则与界面一致：有人工确认就返回确认值，来源标为 `user`；没有就返回模型建议，并标明是哪个模块给出的。人工提示单独列在 `hints` 中。`get_music_record` 保留原始记录结构，不合并 `suggested`、`confirmed` 和 `hint`。这些接口传递分析记录，不传输音频文件内容。

外部分析的字段附带任务、模型和证据来源。时间轴查询支持 `insight`、`loudness` 和 `event`，默认排除过期或被拒绝的字段建议，仍保留人工确认值。完整记录保留历史任务、批次及其输入快照；概览返回任务摘要、当前有效解读与事件、覆盖范围和警告。

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
| `music` | 仅安装独立旋律环境 `.venv-music`，不改动已有基础环境 |
| `all` | 全部 |

在 **设置（`⌘,`）→ 分析环境** 查看 FFmpeg、Python 依赖和模型缓存，按功能下载缺少的权重。首次准备 Demucs 时可能需要安装转换依赖。Python 不在默认路径时，可用 `PYTHON` 和 `PYTHON_MODERN` 指定 3.10 和 3.12 的解释器。

旋律环境固定使用 Python 3.12、NumPy 1.26.4 与 Essentia 2.1b6.dev1389（macOS 15 arm64 包）。它不需要额外权重；首次安装全部功能用 `./script/setup.sh all`，已有基础环境时可单独运行 `./script/setup.sh music`。新版本增加分析功能时只补查此前缓存中没有的功能。

环境检测结果会按运行目录保存。首次没有记录时自动检查一次，之后切换页面或重启 App 都会复用结果，点击「重新检查」才会重新全量检测；下载模型后只更新并保存对应功能的状态。切换运行目录时会读取该目录的记录，没有记录则首次检查。

在 **功能与模型 → 清理** 可以把模型缓存移到废纸篓，也可以同时移除当前运行目录中的 Python 虚拟环境和 Music2Emotion 安装。清理后会重新检查状态，歌曲、分析结果和自行指定的 Whisper 文件会保留。模型缓存可能由其他工具共用，清倒废纸篓后可释放空间。

### 启动 App

1. 用 Xcode 打开 `MusicIntelligenceTool/MusicIntelligenceTool.xcodeproj`，运行目标选择 **My Mac**，按 `⌘R` 运行。也可以在终端运行 `./script/build_and_run.sh`。
2. 点击工具栏中间的「设置」（或按 `⌘,`）切到设置页，在 **分析环境** 中点「运行目录」旁的「选择…」，选中本仓库根目录。从 Xcode 运行时，如果仓库里已经有 `.venv`，App 会自动使用它。设置完成后，点「工作区」回到编辑界面。
3. 点击「打开音频…」，或从 Finder 将一个 WAV、MP3、FLAC 或 M4A 文件直接拖入工作区。已有音频时，拖入新文件会切换歌曲并恢复其保存的标注；分析进行中请先等待或取消后再切换。想先熟悉操作，可以点「试听内置练习曲」，不安装模型也能编辑。

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

连接后，可以让 agent 调用 `get_music_record(track_id)` 读取完整记录，也可以粘贴「复制交接文本」生成的内容。App 退出后，导出的 JSON 仍然可以单独读取。

### 直接发送给 Claude Code

普通 HTTP MCP 连接用于 agent 主动查询。点击按钮直接通知当前 Claude Code 会话，需要另外启用 [Claude Code Channels](https://code.claude.com/docs/en/channels-reference)。这是 Claude Code 的研究预览功能；自定义 Channel 需要使用官方提供的开发加载参数，Team 和 Enterprise 还需组织策略允许。

在仓库根目录注册本地 stdio Channel，然后启动 Claude Code：

```sh
claude mcp add --transport stdio music-intelligence-channel -- \
  "$PWD/.venv/bin/python" \
  "$PWD/MusicIntelligenceTool/MusicIntelligenceTool/Backend/music_channel.py"

claude --dangerously-load-development-channels server:music-intelligence-channel
```

按 Claude Code 显示的提示确认加载本地开发 Channel。保持会话打开，在 App 中点击「发送给 agent」即可。接收服务只监听 `127.0.0.1:18766`；它接收当前完整记录，通过 MCP 通知 Claude，并提供 `get_music_handoff(handoff_id, offset, limit)` 分页读取，每页最多 100 个条目。Claude 应持续读取到 `next_offset` 为 `null`，按顺序合并各页的 `record.marks`；每页都保留其余完整元数据。

底部状态会区分「已通知」「正在读取」和「已读取完整记录」。只有 agent 实际读取全部条目后才显示已读取；30 秒内未确认读取会提示检查 Channel。切换歌曲会清除旧交接提示，并允许立即发送新歌曲；已排队的事件仍可在原会话中继续读取。Channel 事件本身不保证 Claude 已处理数据，也不表示它已经完成总结。交接快照只保存在接收服务当前会话的内存里，服务重启后需要重新发送。

未启动 Channel、端口被占用或客户端不支持此功能时，可以使用「复制交接文本」或「导出 JSON」。如需修改 Channel 端口，在 App 和启动 Channel 的终端中同时设置 `MIT_CHANNEL_PORT`。一个端口对应一个接收会话；多个会话需要使用不同端口。

<details>
<summary>可选的环境变量</summary>

| 变量 | 作用 | 默认值 |
|---|---|---|
| `MIT_MCP_PORT` | MCP 服务端口，优先于设置页中的端口 | `18765` |
| `MIT_CHANNEL_PORT` | App 与 Claude Code Channel 使用的本机接收端口，需两端一致 | `18766` |
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
| 主导旋律 | [Essentia](https://essentia.upf.edu/)、[许可说明](https://essentia.upf.edu/licensing_information.html) | [Melodia 官方方法与示例](https://essentia.upf.edu/tutorial_pitch_melody.html) |
