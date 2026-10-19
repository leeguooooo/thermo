# AI 工具体验验收

2026-10-19：MCP / Skill 的体积、连接阶段、调用观察和任务对照已实现，新增的对照条件检查、媒体文本标记和 schema 引用提示已补完完整 Release 验证。固定源码包为 1.1.31（508）；安装版在验收期间推进到 1.1.32（508），所以该包不是升级候选。博客 Skill 的四份真实模型输出均通过，但对照环境检查失败；尚不能给全部工具排真实业务质量名次，也没有证明 Skill 的整体净收益。

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

## 显式验收入口

新增入口只验收指定的固定源码和已生成包，不安装、签名、发布，也不创建 hook 或定时任务：

```sh
python3 scripts/verify-ai-release.py \
  --source /path/to/fixed-checkout \
  --package /path/to/candidate-dist \
  --output /path/to/new-evidence \
  --release-evidence /path/to/existing-release-tests \
  --plan
```

先用 `--plan` 查看范围，去掉它才执行检查。输出目录必须是源码、包之外的新目录。不传 `--release-evidence` 时会以一个 job 跑 Release 测试，排除 HardwareTests；复用时核对 `freeze.json`、终止状态、日志中的七套通过记录和源码哈希，记录为复用而非本次重跑。入口自己运行的测试也会生成同样的可复用证据；stdout 和 stderr 分开保留，派生的测试合并日志只用于套件核对，不作为时序记录。

入口复用签名、最低系统版本及 CLI 检查，并对 arm64 / Rosetta 分别验证关键 AI 诊断契约、版本身份和输入包完整性。每项保留日志、退出码、超时或中断状态；失败即停，不重试，不回滚他人的修改。`result.json` 的 `complete` 只表示这些检查完成，不代表 GUI、安装版或可复现构建验收。退出码 0 为完成、1 为失败或未完成、2 为输入不合格。`--check-timeout` 设置每项包检查的秒数，默认 240，范围 1–3600；Release 测试使用单独的 1800 秒上限。

维护入口的控制用例：`PYTHONDONTWRITEBYTECODE=1 python3 scripts/test-ai-release-verifier.py`。它只使用自有临时 Git 仓库、文件和进程，不构建或安装 App。

## 当前验证状态

[原生累计 token 快照](measurements/native-cumulative-token-snapshots-2026-10-19.json)：真实日志的 898 条数值投影在旧版全部列为不支持；新版保留 8 个会话各自的最新快照，与独立核对的原始计数一致。App / CLI / JSON 单列累计输入、缓存、输出与推理数值，不与请求或工具返回合并，不跨会话求和，也不把更早或继承的历史算成窗口用量。乱序记录按时间选取，同一最新时刻冲突则数值未知，缺失字段不补零；旧报告保持未测量。711 项相关模块测试及 7 项新增聚焦测试通过，最终编译 CLI 再次核对；[中文离屏图](measurements/native-cumulative-token-snapshots-zh-2026-10-19.png)使用合成展示数据，不是安装版或业务验收。尚未安装或发布。缓存计量参考[官方说明](https://developers.openai.com/api/docs/guides/prompt-caching)，本地累计快照不据此换算账单。

[无扩展名相对引用](measurements/skill-extensionless-reference-2026-10-19.json)：补上 `references/guide` 这类静态路径的检查；存在文件通过，缺失文件带原始行号提示，片段和查询参数去重，远程及动态路径仍跳过。286 项 AgentDoctor 测试及隔离 HOME 的编译后 CLI 检查通过。初扫用户 Skill 未发现这种链接，问题由有效路径反例复现，不作为已安装 Skill 故障或业务收益证据；尚未发布。

[插件根目录 Skill 与说明契约修复](measurements/skill-root-cache-and-contract-2026-10-19.json)：修复 `skills:["./"]` 被误判越界，恢复 12 个缓存条目、218,622 字节；原有 215 个缓存文件哈希一致。冻结的真实缓存副本在旧版漏计、新版计入，空路径、绝对路径及逃逸符号链接仍拒绝，缓存条目不提供删除操作。29 项发现测试及 701 项相关模块测试通过。既有 thermo-use 的源码另修复 YAML 描述、缩短发现文本并补齐 AI 计量用法；严格校验、原生发现及四组受控 CLI 路线通过。旧版同样能被当前 Codex 发现，不能称为加载故障。目录描述 cl100k 参考量由 478 降至 138，完整文件却由 4,238 增至 4,589；没有证明整体节省或业务收益。Skill 改动仅在其源码仓库提交，未推送，已安装版本化缓存未改，未新增副本；此修复未打包安装或发布。

[1.1.31（508）固定源码验收](measurements/ai-tools-release-1.1.31-508-2026-10-19.json)绑定 0381f53，保留已提交的主窗口退出和 legacy helper 升级注册保护：七套件 1,721 项 Release 测试、0 失败，排除 HardwareTests；arm64 / Rosetta 各九组打包后 CLI 检查通过。App / CLI / helper 的双架构、严格签名与 macOS 13.0 元数据检查通过。该包为无更新源的 ad-hoc 包，未公证、安装或发布。

完整 Release App 的隔离副本验证了媒体文本和截断标记、原生图片不计入文本、中文本地 schema 引用提示，以及任务对照中“结果通过、条件失败”的分离。正常合成报告替换后旧警告消失，失败和超时仍参与合适的统计；清除后报告移除。两个架构的运行时代码节均与原包匹配，窗口操作仅在 arm64 上进行。它不代表真实业务、硬件或安装更新验收。

版本适用性检查没有通过：安装版从 1.1.31（506）更新到 1.1.32（508），变动来源未由本轮归因，本轮没有执行安装。当前安装版随包 CLI 用自有夹具验证了对照条件检查和媒体标记，尚未报告缺失的本地 schema 引用；未验证其 GUI。固定包的 508 与安装版的 508 不能据此当作同一源码，不能拿较旧包覆盖当前安装版。更早的 1.1.29（499）仅保留为整合前基线，其 1,716 项测试不与上述结果累加。

[包源码追踪补充](measurements/build-source-metadata-2026-10-19.json)为后续新包记录提交号及 Git 工作树状态，并在“关于”和 `thermo --version --json` 中显示。CLI 自身版本与所在 App 包的数据分开，旧包保持来源未知，独立 CLI 不借用当前仓库或邻近 App 的提交号。提交号、状态或版本在编译期间变化会拒绝组装。749 项相关测试、受控源码状态与 CLI 检查、真实调试包及三种原生显示状态通过；这不是对旧包追填来源，也不是运行中二进制或可复现构建证明。此补充只完成 arm64 Debug 验证，未安装或发布。

[489 历史记录](measurements/ai-tools-integrated-489-2026-10-17.json)保留外层列表展开至 22 项且分母不变、MCP 与外层分开、Skill 正文与回执独立、单日志原生选择、参考总量不完整时保持未知等交互证据。其七套件 1,693 项测试与旧包验收只对应当时源码，不覆盖后续改动。

[外层工具返回明细](measurements/outer-tool-usage-2026-10-17.json)的三份选定真实日志投影，252 次调用、214,531 字节在新旧二进制中一致，MCP / Skill 行也完全一致。只按日志工具名分组，不从脚本推断内部 CLI；明细与原合计是同一批记录，不可再次相加。这不是全量使用统计。[三条 Bash 错误复核](measurements/tool-error-triage-2026-10-17.json)确认了空通配符、原生握手字段假定和历史验证脚本编译错误，未确认 MCP 服务故障，原有错误计数保持不变。

[媒体文本与截断标记](measurements/tool-result-text-representation-2026-10-19.json)：从最近日志的局部扫描发现截图结果后，核对同一完整会话中的七次截图记录。七个结果都是外层文本中包含图片 JSON，且媒体数据带明确截断标记；458,255 字节只是日志保留的文本，不是完整返回或图片 token。新增按结果计数的 `serializedMediaTextResults` / `truncationMarkerResults`，App 和 CLI 据此显示提示，保留既有字节、token、状态和排序。启发式与 cl100k 的完整会话新旧对照均一致。未确定包装和截断产生在哪一层，未据此认定 iPhone MCP 服务故障。已补完整 Release 验收，并验证当前安装版 CLI 支持这两个字段。

本机 Skill、CLI、配置、共享入口、Unity 引用和 Design 代理源码的 2026-10-17 复查仍见 489 记录；本轮没有重启宿主或代理，不推断当前缓存状态。定义批量检查及图标 / _meta 的历史交互见 [474 窗口记录](measurements/ai-tools-ui-474-2026-10-17.json)。479、489、499 原产物保留，508 验收后复核哈希未变。实现与历史细节见 [AI 工具分析](ai-tools-analysis.md)。

## 外部参考与后续证据

[近期使用与点击错误复核](measurements/recent-tool-usage-and-click-triage-2026-10-19.json)：在 00:00–03:48 UTC 的 11 份 Codex 日志局部样本中，MCP 返回文本共 505,306 字节，浏览器快照占约 73.3%；外层 exec 另有约 2.35 MB，不能归入内部 MCP。五份文件被裁剪，不是全量排名。七次明确点击错误为六次遮挡拒绝、一次过期引用，其中两组重复撞到同一遮挡；未确认服务故障。由此修复 chrome-use 的错误分类：遮挡拒绝单列 `element_occluded`，避免遮挡文字中的 timeout / connection 被当作可重试的超时或连接问题。21 项远程分类回归通过；首次完整测试因远程磁盘保护中止，失败记录保留。后续含此修复的主线已通过 [2,366 项普通回归](measurements/mcp-snapshot-incremental-2026-10-19.json)，未执行全部默认跳过的浏览器测试。改动已在 chrome-use 主线提交，未发布、未更新安装版，也未重放浏览器操作；提速及 token 收益未知。

- [MCPJam Inspector](https://www.mcpjam.com/features/inspector)：工具请求 / 响应、调用瀑布和跨客户端测试。
- [ccusage](https://github.com/ccusage/ccusage)：本地会话统计；会话 token 不应直接分摊成某个工具的独占成本。
- [Anthropic skill-creator](https://claude.com/resources/articles/improving-skill-creator-test-measure-and-refine-agent-skills)：触发评测、Skill 对照、验收、耗时及 token。
- 其余目录计量与风险检查参考及适用边界见 [外部参考](ai-tools-analysis.md#外部参考)。2026-10-17 的参考收集为资料研究，新增终端实测范围见下文。没有把外部工具的完整体验评成名次，也没有默认上传个人配置或日志。

[2026-10-19 终端对照与静态检查补充](measurements/mcp-inspector-reference-2026-10-19.json)已实测官方 Inspector 2.11.0、MCPJam CLI 5.16.1 的正常、工具错误、协议错误、schema 与返回契约案例。对照发现的缺失本地 `$ref` 目标，已补进 Thermo 的定义提示；合法布尔 schema 保持无提示，定义计量不变。资源标识符、远程引用、锚点及超过预算者不在此项解析范围，未拉取外部 schema。692 项相关回归、四组编译后 CLI 案例和隔离原生窗口通过；尚未发布，不据此评定真实业务质量。

[MCP 快照增量入口](measurements/mcp-snapshot-incremental-2026-10-19.json)：为 `chrome_use_snapshot` 暴露既有 CLI 的 `diff: true`，默认仍返回完整树；修正切换 filter 后误用旧基线的问题。2,366 项普通回归、格式检查及 1 项隔离 Chrome 用例通过：无变化提示、换过滤条件回退完整树、原 ref 点击及页面回执均核对。自有页面的首次完整回复与后续无变化回复为 3,650 / 2,547 字节，只是该序列的 daemon 返回体积，不代表任务或模型 token 节省。改动已合入 chrome-use 主线，未发布或改动安装版。

## 博客工作流的真实模型对照

[2026-10-18 四次运行记录](measurements/blog-skill-business-eval-2026-10-18.json)：从已观察到的博客 Skill 加载量和拆分后的共用检查缺口中选定文章整理、内容审核两类任务，固定 gpt-6.1-sol / medium，以原版/优化版、优化版/原版的顺序运行。每次最多 120 秒，没有重试。输入为隔离文章夹具；发布工具是离线替身，草稿只做夹具 dry-run，审核只读。不是线上文章验收。

| 任务 | 原版 / 优化版输出验收 | 原版 / 优化版累计输入 token | 原版 / 优化版耗时 |
|---|---|---|---|
| 整理静态 HTML | 均通过 | 147,470 / 121,213 | 40.8 / 37.8 秒 |
| 审核内容 | 均通过 | 277,766 / 163,826 | 87.0 / 57.0 秒 |

草稿通过真实生产输入解析器，保留数字、计量边界和样式，清除脚本并修正图片域名。两份审核报告都识别七项应报错误、两项非阻断警告及两类无依据收益结论，并区分正文发布身份和合法内部元数据。四次均有原生 `turn.completed` 用量、输出文件和父级验收，受保护输入没有改变。优化版在审核时成功读取了完整引用文件；未观察到整份引用返回不等于证明没有读取。

累计输入包含缓存命中，缓存字段不能再次相加；输出 token 分别为草稿 1,474 / 1,626、审核 3,242 / 2,500。命令执行数不是模型轮数，后者仍记未知。两组累计输入分别少 17.8% 和 41.0%，仅为这次配对观察，不是文件长度减少比例或账单节省。

四次任务均结束后，共享 Codex 配置哈希检查失败，执行器以 1 退出，未生成正常完成标记。配置变更来源未确认，也没有覆盖或回滚配置。执行使用 `--ignore-user-config` 和固定显式参数；另行复核的全局指令/旧版 Skill、二进制、平台与 Node 环境指纹仍匹配，冻结输入未变。保留全部结果和异常，不将这次对照标成环境验收通过，也不据此宣称稳定提速或因果收益。两类任务各只有一次配对，两版均通过，尚未显示成功率提升。

2026-10-19 补上导入器的运行后检查：任务 `outcome` 与对照 `comparisonCheck` 分开。新格式为版本 2，缺少检查时拒绝导入；版本 1 未声明检查的旧记录保留结果但不参与收益计算。双方都声明检查通过才进入配对统计，检查失败或未核实者列出排除原因。App 和 CLI 另显示全部导入运行的任务结果，避免把对照无效误写成任务失败。

[这四次实测的派生记录](measurements/blog-skill-business-comparison-guard-2026-10-18.json)保留原始记录哈希，将整组运行后的检查标为失败；没有重跑模型或修改原始记录，版本哈希补计完整 Skill 文件集合。新 CLI 导入后保留双方各两次通过，排除两对，收益差值未知。[原定向验证](measurements/task-comparison-postrun-check-2026-10-19.json)及上述完整 Release 验证均已完成。当前安装版随包 CLI 也通过同一派生记录的检查，不再把它描述成仅在源码中存在的功能；安装版 GUI 未在本轮操作。

真实业务质量与 Skill 净收益仍需持续从实际任务中寻找可复现证据；不能用格式检查、定义长度、一次鉴权失败或合成 UI 数据代替。Figma 独立连接、其他宿主覆盖、大列表辅助功能、截图工具瞬态错误及正式安装更新仍保留各自边界；本次没有通过扩大权限或操作设备来消除未知。
