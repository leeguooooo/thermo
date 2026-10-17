# AI 工具体验验收

截至 2026-10-17，统计、连接检查、本地调用观察和任务对照已有可用实现；实际业务质量与 Skill 净收益仍没有完整结论。[本机最新连接记录](measurements/mcp-auth-scope-and-coverage-2026-10-17.json)已尝试 Codex 全部 9 个启用配置，其中 8 个完整返回 305 个工具，定义数组合计 217,929 个 cl100k 参考 token，服务指令另计 893 token。Figma 独立检查需要鉴权，定义大小未知；当前代理会话的 `mcp__figma__whoami` 能返回帐号资料。两个通道的凭据和身份没有关联比对，不互相替代。

这些数字是不同时间、不同配置的独立计量，REA 使用下述输出声明配置；不是宿主实际加载上下文或账单。其他宿主尚未完成主动测量。[本地候选 1.2.0 (421)](measurements/ai-tools-integrated-421-2026-10-17.json)已完成 1,571 项 Release 回归和双架构各七组 CLI 验证。它固定在 d3bcc8c 主线来源、cd69c65 候选源码，不包含后续并行充电 UI 等提交；可见 GUI 验收因当前锁屏未完成，不能标为可发布。

| 原始问题 | 当前能力与证据 | 仍不能据此判断 |
|---|---|---|
| MCP 总体有多大、占多少 token | 汇总已完整检查配置的定义字节、定义数组和服务指令计数，支持启发式与两种参考编码。本机 Codex 已完整测量 8 / 9 个配置。[连接与范围](measurements/mcp-auth-scope-and-coverage-2026-10-17.json)、[批量原生验收](measurements/mcp-batch-inspection-2026-10-17.json) | Figma 定义及其他宿主未完成计量，总体未知；不把未完成项当零，不把独立配置相加称为实际会话上下文 |
| 哪个工具占用最多、耗时多久 | 定义及返回文本排名、分类返回合计和占比；握手、列表、本地分析时间，以及日志中位数 / P95 / 累计观察间隔。[占比验证](measurements/tool-usage-return-shares-2026-10-17.json)、[完整 App 验证](measurements/tool-usage-native-qa-2026-10-17.json) | 连接时间不是业务工具时间；并行间隔相加不是总经过时间。图片、脚本包装和缺失日志无法完整归因 |
| 哪些 MCP 有问题 | 定义结构提示、明确错误与已知状态分母、缺失 / 未知状态、独立 HTTP 关闭诊断和鉴权范围说明。[错误比例](measurements/tool-usage-error-proportions-2026-10-17.json)、[关闭诊断](measurements/mcp-cleanup-diagnostics-2026-10-17.json) | 定义长、断言未通过或独立检查需要鉴权，不等于业务质量差。尚无覆盖实际配置的真实任务质量排行 |
| Skill 是否臃肿或有内容问题 | 目录描述与正文分开计量，别名去重，缓存单列；内容汇总按宿主 / 范围统计，缺失、冲突和未测量单列。[内容汇总](measurements/skill-content-summary-2026-10-17.json)、[占用测试](../Tests/AgentDoctorTests/ContextFootprintTests.swift) | 静态清单不是已加载清单；长度不直接判差；未完整模拟所有宿主的覆盖优先级 |
| Skill 有没有提高效果 | 相同任务 / 验收条件的配对记录；不兼容配对排除，失败、超时和未知保留。[模型试测](../evals/ai-diagnostics/README.md)、[有状态工作流对照](../evals/browser-workflow/README.md) | 明确口径后的三对摘要题和两对有状态任务，两组均全部通过，未显示成功率收益；显式读取增加往返。隐式触发与真实业务净收益仍待测 |
| 有哪些工具值得参考 | 已借鉴 MCP Token Analyzer、MCPJam Inspector、ccusage、skill-creator、Agent Scan 的计量、瀑布、日志适配和证据方法。[参考及实现范围](ai-tools-analysis.md#外部参考) | 文档研究不等于实测排名；没有默认上传远程内容 |

[原生 Codex 请求捕获](measurements/codex-tool-wire-2026-10-17.json)进一步验证了计量边界：0.163.0 在隔离的自有 MCP / 本地模拟后端中，初次请求没有该工具的输入或输出声明；发现工具后才把输入参数转换成类型声明。完整与关闭输出声明两组均执行了工具并收到独立服务端确认，三次请求均没有输出声明标记。因此 REA 的 73.6% 是目录缩减，不能据此推算模型 token 节省。没有调用真实模型，模拟用量也不作为账单；结论仅适用于这条客户端路径。

## 已落地的本机改进

- [REA 清单配置](measurements/rea-mcp-presentation-2026-10-17.json)：仅给 Codex 的 REA 加入 `REA_MCP_OUTPUT_SCHEMA_PROFILE="off"`。207 个工具的所有其他字段一致，同一自有 HAR 返回完整 Evidence 相同。定义由 3,114,003 降至 823,514 字节，约少 73.6%；客户端不再取得输出类型声明，服务端仍校验结果。输入契约、工具、审批和其他配置未变，原配置已备份，未主动重启现有会话。已证明的是目录传输和计量负担减少，未证明实际模型 token 或账单节省。
- [Unity Skill 引用文档](measurements/unity-skill-reference-repair-2026-10-17.json)：两个缺失文件来自与既有文档匹配的上游快照，已核对 blob / SHA-256 后补齐，原文件未改。4 个本地引用全部通过。当前上游同步来源仍不完整，后续镜像可能删除补齐文件；版本受限的恢复脚本默认只检查，不在体检中自动执行。未验证 Unity 业务任务。
- [Design 代理 SSE 等待](measurements/claude-design-relay-sse-2026-10-17.json)：按请求 ID 识别完整响应，避免响应到达后继续等待流关闭。8 个离线用例在配置所用 Python 3.9.6 和 Python 3.14 均通过，鉴权及分发逻辑保持一致。后续真实授权检查完整返回 23 个工具，但没有记录上游 JSON / SSE 类型，不宣称线上提速或业务验收；未主动重启原有实例。

本机 Skill 修复后的盘点保留 138 个已检查目录文件、459 个引用、0 个已采集发现，缓存另有 215 个文件、417 个引用、0 个发现。[修复后盘点](measurements/unity-skill-reference-repair-2026-10-17.json)中的唯一未测量条目已核实为没有 `SKILL.md` 的空目录 `codex-primary-runtime`；没有移除或制造正文来消除提示。[空目录核实](measurements/mcp-http-installed-audit-2026-10-17.json)

## 源码与安装包验证边界

[421 集成验收](measurements/ai-tools-integrated-421-2026-10-17.json)将下列 AI 源码改动连同所选主线的 CLI / 充电 helper 基础合入固定快照。完整 Release 回归 1,571 项、0 失败；arm64 与 Rosetta x86_64 各七组独立 CLI 夹具通过，所有切片签名、架构和 macOS 13.0 检查通过。产物为本地 ad-hoc 包，没有更新源。QA 副本的各架构指令段与原包一致，原包哈希未变；但可见窗口验收未完成，控制台锁屏标志为 true。自有 QA / 模拟服务均已退出，没有解锁或把窗口定位错误当成产品缺陷。

[393 包集成验收](measurements/mcp-native-events-release-2026-10-17.json)对应 ed354ee，包含 1,483 项 Release 测试；全部切片签名、架构及最低系统版本检查通过，arm64 与 Rosetta x86_64 各通过五组 AI CLI 夹具。完整 App 的隔离副本读取两条真实公开文档事件，显示检索 49,697 字节 / cl100k 11,651、原文 3,331 字节 / 716。错误状态、P95 和请求用量保持未知。原包未变，QA 已停止，临时原始事件摘录已移除。[374 包](measurements/ai-tools-integrated-package-2026-10-17.json)保留为历史证据。

393 之后的 AI 源码改动已包含在 421；以下定向与旧版界面证据保留各自的适用范围，不替代新版可见 GUI 验收：

- [返回合计与占比](measurements/tool-usage-return-shares-2026-10-17.json)：31 项针对性测试、CLI 隐藏行分母检查与[中文离屏图](measurements/tool-usage-return-shares-zh-2026-10-17.png)。[完整 App](measurements/tool-usage-native-qa-2026-10-17.json)验证 8 → 16 → 21 项展开、编码旧报告提示和分类独立计量，并修正了过时的“实际用量未测量”说明。
- [Skill 内容汇总](measurements/skill-content-summary-2026-10-17.json)：30 项针对性测试、CLI 和同文件完整 App 前后对照；别名不重复累计，缓存单列，缺失或冲突证据保留。历史逐条计数没有改写，也不把计数下降当成修复数量。
- [关闭诊断](measurements/mcp-cleanup-diagnostics-2026-10-17.json)：29 项针对性测试与编译 CLI 夹具。ZEGO 最新一次列表完整，关闭在 250 毫秒预算下观察约 252 毫秒仍未确认；HTTP 状态未知，不推断服务端最终状态。没有增加重试或超时，新增页脚未做完整 App 验收。
- [鉴权范围说明](measurements/mcp-auth-scope-and-coverage-2026-10-17.json)：16 项针对性测试及真实独立检查，明确配置凭据与宿主管理 OAuth 的边界。当前 Figma 通道的只读帐号调用单独保留证据，不导出身份值、不据此补造定义计数；该说明的完整 App / 包验证仍待完成。

上述验证不替代真实 Intel 主机、全部系统版本、大字体或正式安装更新验收。没有据此授权发布、安装 helper 或切换 AWDL。[受控镜像占用实验](measurements/owned-dmg-busy-control-2026-10-17.json)只证明真实占用时普通卸载拒绝确认清理、结束占用后可成功；此前偶发清理观察的原因仍未解释，没有加入强制卸载或重试。

## 还需要的证据

评测题目由 agent 从使用记录、失败和开销中主动发现，不要求用户出题。后续固定模型、环境、工具 / Skill 版本及验收条件，用新任务 ID 保留配对、重复样本和不成功结果。不要继续重复已两组全部通过的微型题，或根据静态占用默认移除工具、扩大 Skill 注入。

[真实调用抽样](measurements/workflow-discovery-2026-10-17.json)只读取 80 份近期日志尾部，43 份截断，不能当全部使用频率。浏览器样本中 8 组完整观察后又取快照，但没有相同快照，尚不能判为浪费；一次 `expect` 的 `noWait=true`、`pass=false`、`timedOut=false` 说明不能把断言失败归为服务超时。本地浏览器及后续有状态夹具验证了等待最终状态与只提交一次的口径，没有证明生产业务或 Skill 净收益。首轮失效夹具四条记录已保留并排除。

剩余工作包括 Figma 的可授权完整定义计量、真实业务质量与 Skill 净收益评测、421 可见 GUI 及正式安装更新验证。后续并行主线提交不在本次候选中，若选择纳入发布范围，需重新集成验收。硬件相关路径仍按独立授权和实际验收处理；本地通过不等于部署、安装或真实设备通过。
