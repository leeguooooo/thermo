# AI 工具体验验收

2026-10-18：MCP / Skill 的体积、连接阶段、调用观察和任务对照已实现，并完成本地源码、产物及隔离窗口验证。已从实际使用记录中发现并修正参数、说明和维护入口问题。博客 Skill 的两类离线业务任务新增四次真实模型对照，四份输出均通过，但共享配置变更导致环境收尾检查失败；尚不能给全部工具排真实业务质量名次，也没有证明 Skill 的整体净收益。

## 原始问题的当前结论

| 问题 | 已有结果与证据 | 计量边界 |
|---|---|---|
| MCP 总体多大、占多少 token | Codex 9 条启用配置均已尝试，8 条完整返回 305 个工具；定义数组独立计数之和为 cl100k 217,929，服务指令另计 893。[连接记录](measurements/mcp-auth-scope-and-coverage-2026-10-17.json) | 不同时点的独立计量；Figma 独立连接需要认证，其他宿主未完整主动测量，总体仍未知；不是当前提示词或账单 |
| 什么工具占得最多 | 已测目录中 REA 最大：194,330 个 cl100k 参考 token；单项 `compare_web_captures` 为 36,303。[定义排名](measurements/mcp-configured-coverage-2026-10-17.json) | 仅对应记录中的配置和表示方式；目录长度不代表任务成本或质量 |
| MCP 多慢、哪里失败 | 握手、列表和本地计量分开计时；日志显示中位数、P95、累计观察间隔，结果明确报错与宿主调用失败分开。[原生事件解析](measurements/mcp-invocation-failures-2026-10-17.json)、[窗口核对](measurements/ai-tools-ui-474-2026-10-17.json) | 并行调用的间隔合计不是经过时间；条件断言失败不一定是服务故障；缺失与未知不补零 |
| Skill 占多少、是否臃肿 | 静态目录描述、完整文件、缓存和别名单列；Claude 可明确关联的指令正文与回执分开。在一组近七天已关联样本中，4 次加载为 68,714 字节 / cl100k 17,917；博客 Skill 占其中约 84%。[加载记录](measurements/skill-instruction-loads-2026-10-17.json) | 样本经过选择且有截断，不是全量排名；隐式读取、引用文件和其他宿主未完整覆盖；长不等于差 |
| Skill 有没有帮助 | 支持按相同任务、模型、环境、验收条件导入配对记录，保留失败、超时、未知及排除项。[模型试测](../evals/ai-diagnostics/README.md)、[有状态任务对照](../evals/browser-workflow/README.md)、[文件导入验收](measurements/task-comparison-visible-ui-2026-10-17.json) | 三对摘要题和两对有状态任务两组均全部通过，未显示成功率收益；显式读取增加往返，不能据此断言所有 Skill 有用或无用 |

Figma 另经 Codex 0.163.0 已有 OAuth 的只读宿主目录接口取得 44 个工具，规范化数组为 99,847 字节 / cl100k 24,196。目录可能经过宿主适配或缓存，身份、时效与原服务指令没有独立验证，不并入上表八个服务的合计。[Figma 目录及图标 / _meta 拆分](measurements/figma-host-catalog-and-metadata-2026-10-17.json)

## 已落地的改进

- [REA 目录表示](measurements/rea-mcp-presentation-2026-10-17.json)：仅在 Codex 配置关闭输出声明，定义由 3,114,003 降至 823,514 字节，减少约 73.6%。其他工具字段及同一自有 HAR 的完整返回证据一致。原生客户端实验说明完整目录不等于模型请求，不能声称账单减少 73.6%。
- [iPhone Skill 滚动参数](measurements/iphone-skill-scroll-contract-2026-10-17.json)：补齐 MCP 必填的 x/y/dx/dy，并区分 HTTP 简写。实际安装的 0.19.2 MCP 在发送 HTTP 前拒绝旧示例，新示例通过解析与批请求转换。本机受管理根 Skill 已更新；版本化插件缓存未改，没有执行手机手势。
- [博客 CLI 说明](measurements/blog-skill-cli-contract-2026-10-17.json)：纠正 themed / raw HTML 模式说明，与代码行为对齐；本机 CLI 为 0.1.22 的本地说明修正。隔离请求契约验证没有发布文章。[博客 Skill 按需拆分](measurements/blog-skill-progressive-disclosure-2026-10-17.json)将审查程序移到引用文件。[后续共用检查校正](measurements/blog-skill-common-checks-2026-10-17.json)补回默认发布入口应可见的检查，保留既有错误、警告和提示级别；原先约 40% 的数字保留为历史测量。当前正文为 cl100k 4,717，较原来的 7,513 少约 37%。原生客户端预载、引用完整性及本机原子同步已核对。审查任务需另读引用，两份正文独立计数合计 7,864；两类离线任务的真实模型规则遵循已补测，结果及环境异常见下文；整体任务净收益未证实，不将预载缩减称为账单节省。
- [共享 Skill 入口](measurements/shared-skill-maintenance-2026-10-17.json)：修复 message-use、paste-use、sflow 的副本漂移，使共享入口读取安装器维护的来源；[重复副本配置](measurements/codex-skill-dedupe-2026-10-17.json)只停用两组内容相同的 Codex 副本，保留不同工作流。已有会话没有重启，不推断其缓存已经更新。
- [Unity 引用文件](measurements/unity-skill-reference-repair-2026-10-17.json)从匹配的上游快照补齐；[Design SSE 代理](measurements/claude-design-relay-sse-2026-10-17.json)按请求 ID 识别完整响应，避免响应到达后仍等待流关闭。各有隔离验证，不作为 Unity 业务效果或线上提速证据。

## 当前验证状态

[1.1.28 (489) 本地集成记录](measurements/ai-tools-integrated-489-2026-10-17.json)固定源码 668c13b：七套件 1,693 项 Release 测试、0 失败，排除 HardwareTests；arm64 / Rosetta 各八组 CLI 验证通过。通用 App / CLI / helper 的严格签名、架构和 macOS 13.0 元数据检查通过。它是无更新源的 ad-hoc 包，未安装、发布或公证。

489 的完整 Release App 在隔离 Home 中完成可见验收：外层列表展开至全部 22 项且分母不变；MCP 与外层计量分开；Skill 正文排序及回执独立；单日志原生选择只读一份文件；参考总量不完整时保留未知、不生成占比；任务对照保留失败、超时及合成数据标识，清除后恢复空状态。QA 副本的两个架构代码节与原包匹配，实际窗口操作仅在 arm64 上进行。数据为合成记录，不能当作业务收益或普通启动、安装更新、硬件验收。

[外层工具返回明细](measurements/outer-tool-usage-2026-10-17.json)的三份选定真实日志投影，252 次调用、214,531 字节在新旧二进制中一致，MCP / Skill 行也完全一致。只按日志工具名分组，不从脚本推断内部 CLI；明细与原合计是同一批记录，不可再次相加。这不是全量使用统计。[三条 Bash 错误复核](measurements/tool-error-triage-2026-10-17.json)确认了空通配符、原生握手字段假定和历史验证脚本编译错误，未确认 MCP 服务故障，原有错误计数保持不变。

本机 Skill、CLI、配置、共享入口、Unity 引用和 Design 代理源码已在 489 记录中最终复查。已有宿主会话和代理实例未重启，不推断缓存已更新。定义批量检查及图标 / _meta 组件的详细交互证据仍见 [474 窗口记录](measurements/ai-tools-ui-474-2026-10-17.json)；相关定义组件源码未因外层用量改动而变化。[479 历史产物](measurements/ai-tools-integrated-479-2026-10-17.json)保留并复验，旧临时路径不作为当前可用产物的依据。实现与历史细节见 [AI 工具分析](ai-tools-analysis.md)。

## 外部参考与后续证据

- [MCPJam Inspector](https://www.mcpjam.com/features/inspector)：工具请求 / 响应、调用瀑布和跨客户端测试。
- [ccusage](https://github.com/ccusage/ccusage)：本地会话统计；会话 token 不应直接分摊成某个工具的独占成本。
- [Anthropic skill-creator](https://claude.com/resources/articles/improving-skill-creator-test-measure-and-refine-agent-skills)：触发评测、Skill 对照、验收、耗时及 token。
- 其余目录计量与风险检查参考及适用边界见 [外部参考](ai-tools-analysis.md#外部参考)。本轮为资料研究，没有把外部工具的完整体验评成名次，也没有默认上传个人配置或日志。

## 博客工作流的真实模型对照

[2026-10-18 四次运行记录](measurements/blog-skill-business-eval-2026-10-18.json)：从已观察到的博客 Skill 加载量和拆分后的共用检查缺口中选定文章整理、内容审核两类任务，固定 gpt-6.1-sol / medium，以原版/优化版、优化版/原版的顺序运行。每次最多 120 秒，没有重试。输入为隔离文章夹具；发布工具是离线替身，草稿只做夹具 dry-run，审核只读。不是线上文章验收。

| 任务 | 原版 / 优化版输出验收 | 原版 / 优化版累计输入 token | 原版 / 优化版耗时 |
|---|---|---|---|
| 整理静态 HTML | 均通过 | 147,470 / 121,213 | 40.8 / 37.8 秒 |
| 审核内容 | 均通过 | 277,766 / 163,826 | 87.0 / 57.0 秒 |

草稿通过真实生产输入解析器，保留数字、计量边界和样式，清除脚本并修正图片域名。两份审核报告都识别七项应报错误、两项非阻断警告及两类无依据收益结论，并区分正文发布身份和合法内部元数据。四次均有原生 `turn.completed` 用量、输出文件和父级验收，受保护输入没有改变。优化版在审核时成功读取了完整引用文件；未观察到整份引用返回不等于证明没有读取。

累计输入包含缓存命中，缓存字段不能再次相加；输出 token 分别为草稿 1,474 / 1,626、审核 3,242 / 2,500。命令执行数不是模型轮数，后者仍记未知。两组累计输入分别少 17.8% 和 41.0%，仅为这次配对观察，不是文件长度减少比例或账单节省。

四次任务均结束后，共享 Codex 配置哈希检查失败，执行器以 1 退出，未生成正常完成标记。配置变更来源未确认，也没有覆盖或回滚配置。执行使用 `--ignore-user-config` 和固定显式参数；另行复核的全局指令/旧版 Skill、二进制、平台与 Node 环境指纹仍匹配，冻结输入未变。保留全部结果和异常，不将这次对照标成环境验收通过，也不据此宣称稳定提速或因果收益。两类任务各只有一次配对，两版均通过，尚未显示成功率提升。

真实业务质量与 Skill 净收益仍需持续从实际任务中寻找可复现证据；不能用格式检查、定义长度、一次鉴权失败或合成 UI 数据代替。Figma 独立连接、其他宿主覆盖、大列表辅助功能、截图工具瞬态错误及正式安装更新仍保留各自边界；本次没有通过扩大权限或操作设备来消除未知。
