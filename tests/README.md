# 测试范围与运行方式

测试按使用流程组织，优先在现有场景中维护关键约束。普通文案、样式和简单实现细节通过构建或界面检查验证，不为每次小修复增加独立用例。新增测试场景应对应新的用户流程、协议边界或有实际影响的风险。

## 保留的覆盖

| 范围 | 场景 | 主要约束 |
|---|---|---|
| Swift 连接与云端分析 | 4 个流程 | 配置与 Keychain 生命周期、两种 API 及范围边界、校对与缓存、批次失败恢复、双模型对照和依赖失效 |
| Swift 编辑与播放 | 导入 2 个、时间轴 2 个、记录编辑 5 个流程 | 导入切换恢复、非法输入与忙碌状态、定位与选区分离、人工校对保护、各类条目删除撤销与保存、歌词字词清理、局部结果合并 |
| Swift 分析环境 | 3 个流程 | 缓存刷新和目录隔离、下载更新、失败和损坏恢复、取消保护、模型与环境清理范围 |
| Python 分析 | 模型资产 1 个、声学与和声 2 个、活动检测 1 个流程 | 离线检查、已校验文件保护、原始声道与增益、静音边界、时间偏移和真实覆盖 |
| Python MCP 与 Channel | MCP 1 个、Channel 4 个流程 | 本机真实 HTTP／stdio、分页回执、完整记录、确认值与过期建议、跨歌曲交接 |
| 原生界面 | 8 个流程 | 示例引导、注释保存与 JSON 导出、歌词按需准备与连续校对、工作区操作与恢复、歌词右键删除与撤销、各目录菜单及删除保护、Finder 拖入、环境缓存与 MCP 空闲、外部连接配置与空状态 |

三阶段交付保留 26 个独立测试入口，较整理前的 55 个减少 29 个；批次、比较范围、分轨覆盖和第三阶段的关键合并规则已纳入现有流程。计数不作为后续开发的硬性上限，也不通过取消断言来追求数字。

## 运行

在仓库根目录使用已配置的分析环境：

```sh
.venv/bin/python -m unittest discover -s tests -v
./script/check_agent_handoff.sh
```

第一条命令会跳过两项需要原生 Swift 可执行文件的交接测试；第二条命令编译真实 Studio／SongRecord 后补齐，并验证 MCP。HTTP 测试仅监听本机临时端口，不连接外部服务。

Swift 单元测试使用临时构建目录和串行调度，避免桌面目录访问及多个测试宿主相互干扰：

```sh
xcodebuild -project MusicIntelligenceTool/MusicIntelligenceTool.xcodeproj \
  -scheme MusicIntelligenceTool -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/MusicIntelligenceTool-tests \
  -parallel-testing-enabled NO -only-testing:MusicIntelligenceToolTests \
  -skip-testing:MusicIntelligenceToolUITests test
```

需要界面验证时单独选择 `MusicIntelligenceToolUITests`，不要与单元测试混跑。若系统无法启用 XCTest automation mode，保留失败报告，使用内置原生界面工具补充验证，并说明自动化测试未执行。浏览器测试遵守根目录 AGENTS.md 的 Firefox／WebKit headless 限制。

## 音乐算法校准

安装基础环境与 `./script/setup.sh music` 后，可按需运行固定矩阵；它不调用云端、不下载模型，不属于每次小修复必须执行的回归项目：

```sh
.venv/bin/python script/evaluate_music.py --output tmp/music-evaluation
```

矩阵涵盖主导音高与静音、混音干扰、移调动机、复杂和弦、重复与变速片段、噪声抑制、拍点、局部速度、拍号及局部调性。目标阈值定义在脚本中；合成信号的已知频率、节拍和结构提供参考。`--recorded /path/to/audio` 可额外检查真实录音的运行结果与 pYIN 一致性，但不提供带真值的准确率。已完成的校准结果和限制见 [第三阶段评测记录](../docs/stage3-evaluation.md)。

## 测试数据和边界

- 音频使用内置练习曲和确定性的本地合成信号；物理测量的期望值来自已知振幅、频率、相位与时间，不在测试中重新实现分析算法。
- 云端协议测试使用测试 bundle 内的 `cloud_fixture_server.py`，只对本机提供固定响应。它不代表 OpenAI／OpenRouter 的真实可用性或音乐识别质量。
- Keychain 测试使用随机条目 ID 和无法认证真实服务的字符串，结束时删除；其他场景使用注入的内存凭据存储。
- 文件与歌曲记录保存在隔离临时目录；截图、日志和 xcresult 保存在 `tmp/` 或 DerivedData 的测试结果目录。
- 真实云端模型评测需另行选择素材、连接及用量授权，不通过常规回归脚本自动触发。本次按用户要求仅作本地交付，最终收尾不再增加测试。
