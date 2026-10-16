# AI 工具分析

thermo 的 AI 工具页需要回答：配置是否有故障、定义有多大、实际调用是否顺畅，以及 MCP / Skill 是否帮助完成任务。这四项需要不同证据。

## 已实现的静态 Skill 检查

`thermo agents context [--agent AGENT] [--root PROJECT] [--json]` 只读取配置与 Skill 文件，不启动 MCP，不执行工具，不读取会话正文。按完整 SKILL.md 的估算 token 排名，输出目录描述、正文和完整文档的独立测量。App 的 Skills 分类按宿主汇总占用，显示最大的五个独立文件；逐项清单保留所有来源。可在 App 选择 Skill 项目，或回到用户范围。

- 字节、字符和行数来自原始文本，输出不包含正文。
- token 是 `ascii4-unicode1-v1` 启发式估算：每四个 ASCII 标量计一个 token，每个其他 Unicode 标量计一个 token。它不代表任何模型的分词结果或账单。
- 目录项由 name 和完整 description 构成，完整文档含 front matter。两者不能相加当作实际加载量。未读取引用文件。
- 递归检查独立 Skill，找到 SKILL.md 后不继续把其 scripts / references 当作独立 Skill。包含 Codex 的 `.system` 目录。
- 每个文件最多读取 1 MiB，扫描最多处理 10,000 个目录节点、深度 16。无法读取、循环链接或达到上限会报告不完整；统计只覆盖成功读取的文件。
- 使用设备号与 inode 识别文件，符号链接、硬链接和重复来源只计一次文档占用；无法取得文件身份时回退到规范路径。相同正文但独立存储的文件不合并。文件身份仅输出哈希。
- 文档按文件去重，目录描述按文件与插件命名空间去重。同名但不同文件只提示来源重叠，不推断宿主只会保留一个。若扫描期间同一身份出现不同内容，相关文件从总量排除。
- Codex 插件缓存按 marketplace / plugin / version 盘点，支持 portable、Codex 和 Claude 兼容清单。缓存版本可能过期、关闭或由桌面端管理；本地 enabled 只作为配置证据保留，不当成当前加载状态。所有缓存版本单独统计，不混入目录与已配置 Claude 插件的总量。普通扫描不执行 codex plugin list。
- 项目范围只在显式传入目录后读取：从所选目录向上至 Git 根标记的 `.agents/skills` 和 `.claude/skills`。没有 Git 根标记时只查所选目录，不扫描无关父目录；不递归搜整台机器的仓库。项目目录选择后会清掉旧范围报告，再扫描；进行中的检查和修复不接受范围变更。
- 嵌套、项目和 Codex 缓存条目不提供删除操作，避免沿合集链接移除共享目标。

汇总是静态清单，不是最终会话上下文；目录描述和完整文档也不能相加当实际消耗。JSON 的 summaries 区分条目数、成功测量数、独立文件数、重复文件条目、目录估算、文档估算、缓存数量和变化 / 身份未知的排除项。按 --agent 过滤会同时保留对应共享来源与覆盖警告。

仍未覆盖管理员目录、宿主通过远程服务提供的 Skill、会话内动态加入的目录、宿主配置的完整优先级与启用覆盖规则。工作树主检出回退规则也未模拟。因此不能把静态目录总量称为“该宿主当前加载的全部 Skill”。

发现规则参考 [Codex Skill 位置与同名行为](https://developers.openai.com/codex/skills)、[Codex 插件缓存布局](https://developers.openai.com/plugins/build/plugins)、[Claude Code 项目 Skill 与同名规则](https://code.claude.com/docs/en/skills)。这些规则于 2026-10-17 核对；实现对未识别的加载状态保持未知。

## Skill 内容证据

每份成功读取的 Skill 增加 quality 元数据。解析由固定版本的 [Swift Markdown 0.9.0](https://github.com/swiftlang/swift-markdown/tree/0.9.0) / cmark-gfm 完成，依赖提交记录在 Package.resolved 中。检查不执行 Skill、脚本或 MCP，不联网获取引用，也不读取引用文件正文。

- 检查 Markdown 链接、图片和已解析的参考式链接，保留原 SKILL.md 行号。代码块、行内代码、HTML 注释和未解析成链接的括号文字不会当作文件引用。
- 只核实静态相对路径。URL、绝对路径、锚点、变量和 glob 不查；编码空格和嵌套括号按 Markdown 解析，父目录引用从真实的 Skill 文件位置解析，避免链接目录改变 ../ 的含义。
- 目标不存在与无权限 / 无法核实分开处理。缺失引用明确写“当前不存在”，提醒判断它应随 Skill 打包还是使用时生成，不宣称 Skill 一定不能用。
- 去掉元信息和注释后没有正文会列出 empty_body；没有长度评分，也不把长文档直接判为差。
- 同一宿主下、独立文件的 SKILL.md 完全相同会给 info 提示和来源，别名 / 硬链接不算独立副本。缓存的多版本不参与重复安装提示；缓存引用问题只作信息证据，不当成已加载版本的健康故障。
- 每份文档最多处理 100,000 个语法节点、512 个引用；取消或达到上限明确标为检查未完成。HTML href、引用锚点正确性和任务语义不在检查范围。

App 显示内容检查数量，问题详情给出来源及行号；信息条目也可展开证据。旧报告没有 quality 时显示尚未采集，不能用 0 个问题代替未知。

[本机盘点与隔离验收](measurements/skill-quality-2026-10-17.json)记录了 Codex 范围的 355 个文档条目、876 次本地引用检查和 2 个当前缺失的目标；未包含 Skill 名称或路径。`scripts/verify-skill-quality.py` 用编译后的 CLI 核实引用位置、正文空缺、副本和不执行 MCP、不改 Skill 的边界。

Swift Markdown 与 swift-cmark 的许可证、NOTICE / COPYING 保存在 Resources/ThirdPartyNotices。构建脚本将它们带入 App、CLI ZIP 和 GitHub Release tar 包；本轮验证的是独立目录中的 Debug ad-hoc 包和归档布局，没有公证、安装或发布。root helper 未链接 Markdown，原生离屏预览脚本也已复核可运行。

## MCP 主动检查

普通体检仍只检查配置，不启动任何 MCP。`thermo agents inspect NAME [--agent AGENT] [--timeout SECONDS] [--json]` 或 App 的“连接并检查”会显式启动选定的 stdio 服务或连接配置的 Streamable HTTP 地址，执行 initialize、notifications/initialized 和完整分页 tools/list，不调用业务工具。不改写配置。stdio 使用自己启动的子进程；HTTP 建立新的检查会话，不接管其他客户端的会话。

结果分别给出启动、握手、列表和总耗时，以及服务 instructions、完整工具定义数组、逐工具描述、输入 / 输出 schema 和 annotations 的静态占用。完整定义用排序键的紧凑 JSON 测量，正文不导出；工具名称脱敏，服务返回的错误正文不回显。分项估算不保证相加等于完整 JSON 的估算；未测量宿主的包装、延迟加载或缓存。

- 当前支持 stdio、Streamable HTTP 和 2024-11-05、2025-03-26、2025-06-18 协议版本。HTTP 支持 JSON 和增量 SSE 响应，SSE 包含 LF、CRLF、CR 换行及分块 UTF-8 文本；取得响应后不等待长连接自然结束。旧版独立 SSE 端点发现和 OAuth 登录未实现。
- 默认总时限 10 秒，最大 120 秒。采用单调时钟，所有读写非阻塞；超时、取消、协议错误、断流和大小上限返回未完成。
- stdio 单条待解析消息或单次 HTTP 响应最多 8 MiB，整个检查最多接收 16 MiB；最多 100 页、10,000 个工具。重复或无效游标拒绝作为完整清单。
- 不向服务声明 sampling、elicitation 或 roots 能力；只响应 ping，其他服务发起的请求返回不支持。
- 关闭自己启动的子进程：先关 stdin，短暂等待，再依次 TERM / KILL；不会结束用户已经运行的 MCP 实例。HTTP 不启动进程，连接建立计入握手时间，启动时间保持空值。
- 缺失描述、缺失 / 非对象输入 schema、错误 schema type 和重复工具名给出具体提示。它们是定义问题，不能直接推断任务成功率。

HTTP 保留配置中的请求头，支持 Codex 的 bearer_token_env_var 和 env_http_headers。缺失环境变量、401 / 403 或认证挑战明确报告 authenticationRequired，不调用登录流程，不使用系统凭据或自动 Cookie，不跟随重定向，也不重放失败的请求。协议保留的会话头、版本头及传输字段不能由普通配置请求头覆盖。

HTTP 在初始化收到新会话 ID 后验证可见 ASCII 字符和长度，再将其与协商的协议版本带到后续请求。关闭时只对这次新建的会话尝试一次 DELETE，最多额外等待 250 ms。JSON 的 cleanupStatus 区分 closed、not_needed、server_retained 和 unconfirmed；工具清单成功不代表会话关闭已确认。会话 ID、凭据和响应正文不写入报告。

本机 CodeGraph 已完成一次真实握手和完整工具列表读取，见 [测量记录](measurements/mcp-codegraph-2026-10-17.json)。这次未调用 codegraph_explore，不代表业务调用已验收。App 当前通过编译，检查结果页已完成[中文原生离屏渲染检查](measurements/mcp-inspection-zh-2026-10-17.png)；这不是已安装 App 中点击与取消的实际验收。

公开的 OpenAI 文档 MCP 已实际完成 HTTP 握手并读取 5 个工具，见 [HTTP 测量记录](measurements/mcp-http-openai-2026-10-17.json)；该服务未返回会话 ID。状态会话、完整分页、SSE 分块、认证失败、超时、取消和关闭请求另由本地 HTTP 夹具验证。没有调用文档检索等业务工具。[HTTP 中文结果页](measurements/mcp-http-inspection-zh-2026-10-17.png)为原生离屏渲染，长列表可在实际窗口中滚动；尚未完成已安装 App 的点击操作验收。

协议实现依据：[生命周期](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)、[stdio 传输](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)、[工具列表](https://modelcontextprotocol.io/specification/2025-06-18/server/tools)。

## 本地使用历史

`thermo agents usage [--since ISO_DATE] [--agent claude|codex] [--limit FILES] [--all] [--json]` 显式读取本地会话日志。默认最近 7 天、最多 100 个文件；日期简写 YYYY-MM-DD 按 UTC 解释。App 的 MCP / Skills 分类共享一次“分析本地日志”的结果，支持按返回文本、明确错误、观察耗时或次数排序；项目选择不会改变这块跨项目统计的范围。

- 来源是 `~/.claude/projects` 与 `~/.codex/sessions` 中最近修改的 JSONL 文件，不包含归档目录。只处理窗口内、带有效 ISO 时间戳的记录。按文件修改时间选择意味着保留旧修改时间的导入日志可能不在范围内。
- 最多发现 20,000 个目录条目，递归深度 6；最多读取 64 MiB，每个文件只读末尾 4 MiB，单行最多 1 MiB，扫描阶段最多 20 秒。超限、取消、截断、无法读取、无效 JSON 和缺失关联均在 coverage 或调用条目中保留。读取使用打开文件的长度快照，未结束的末行不作为完整事件。
- 通过宿主、会话与 call id 关联调用和结果，过滤重复记录。调用按开始时间归入窗口；窗口外开始、窗口内结束的不算新调用。支持 Claude 的 tool_use / tool_result、Codex 的 function_call / custom_tool_call 及对应结果。MCP 只识别日志中直接出现的 mcp__server__tool 名称；不解析脚本字符串推断嵌套调用。其他工具调用保留数量，不能据此断言其中没有 MCP。
- Skill 目前只识别 Claude 显式 Skill 工具调用。隐式注入、通过普通文件读取加载 Skill，以及 Codex 的 Skill 使用不能完整识别。没有观察到记录不等于没有使用。
- 结果出现算 completed；只有明确布尔 is_error / isError 标记才归为已知错误状态。普通返回文本里的 ERROR 字样不会被猜成失败，缺少状态标记保持未知。结果缺失也不等于失败或成功。
- 耗时是日志调用至结果的时间间隔，包含宿主和传输开销，不代表纯服务执行时间。异常负间隔不计入样本。中位数依有效样本计算，至少 20 个样本才给最近秩 P95；累计间隔可能互相重叠，不能当作实际经过时间。
- 返回文本单独计量，JSON 的 returnedTextEstimator 标识启发式算法版本。标准内容块只统计 text；图片等非文本块计数但不估算 token。结构化输出仅在没有 content 时序列化计量，避免把同一结果重复加总。报告只保留工具 / Skill 名称与聚合数字，不写入提示词、其他参数或返回正文；Skill 名称须通过标识符字符校验。脱敏后同名的工具也用原始名称哈希保持独立。
- 请求 token 单独列出：Claude message.usage 与 Codex token_usage_record.payload.usage。原生 msg_ / resp_ ID 跨镜像日志去重，其他 ID 在会话内去重；渐进计数使用较新的记录。Codex 累积 token_count 不求和。缺失或不支持的记录保留计数，缓存字段缺失保持未知；不同宿主的缓存字段不归一化、不再与 input 相加。

请求 token 不分摊给工具，也不根据调用所在的整条模型消息推算工具占比。这份报告不提供账单、任务成功率或“哪个版本的工具更好”的结论。按照日志名称汇总也不能证明它对应当前安装版本。

[本机聚合观察记录](measurements/observed-tool-usage-2026-10-17.json)分别保留了 Codex 两个文件和 Claude 二十个文件的窗口、覆盖限制及调用数量，不包含提示词、工具名称、项目路径或原始 token 计数。`python3 scripts/verify-tool-usage.py .build/debug/thermo` 在独立临时 Home 中运行编译后的 CLI，核实并行 MCP / 显式 Skill 计数、请求 token 分离、图片未知与正文不导出。App 已接入分析入口；[中文原生离屏预览](measurements/observed-tool-usage-zh-2026-10-17.png)使用[合成夹具](measurements/observed-tool-usage-fixture-2026-10-17.json)，不是真实工具性能样本。预览由 scripts/render-tool-usage.py 直接编译面板与当前玻璃样式生成，未操作已安装 App；实际窗口操作验收仍待完成。

## 后续实现与验收

| 能力 | 完成所需证据 |
|---|---|
| 按宿主统计 Skill 总量 | 证明目录发现规则、插件命名空间和别名去重符合对应宿主；同时保留安装条目和有效条目的差别 |
| 模型分词 | 使用有版本的 tokenizer 和跨语言样例验证；不支持的模型明确显示估算 |
| MCP 定义分析 | stdio / Streamable HTTP 的 initialize、完整分页 tools/list；超时、认证、错误与取消均不能变成空清单 |
| MCP token 排名 | 拆分 instructions、工具描述、输入 / 输出 schema、annotations；区分完整定义与宿主实际暴露的定义 |
| MCP 连接测量 | 独立记录启动 / 握手 / 列表耗时；不因检查自动调用业务工具；只有足够样本才给分位数 |
| 使用历史 | 本地适配 Claude / Codex 日志，标注时间范围、日志覆盖与关联规则；并发调用不能重复分摊整条模型消息用量 |
| 内容问题 | 缺失引用、重复定义、描述或 schema 问题给出具体位置；长度本身只作提示，不直接判定质量差 |
| 任务效果 | 固定任务、模型与环境，对照有 / 无 Skill 或不同工具版本；验证结果、耗时和 token，保留失败与波动 |
| App 验收 | 中文 / 英文、大字体、长路径、空清单、不完整清单与多来源条目的实际渲染及操作检查 |

## 外部参考

- [MCP Token Analyzer](https://github.com/tjhop/mcp-token-analyzer)：工具定义按组成部分拆分。其 tiktoken 统计对 Claude 只是近似；不将所有可发现的定义相加称为实际会话消耗。
- [MCPJam Inspector](https://www.mcpjam.com/features/inspector)：请求响应与调用瀑布图，连接检查和业务工具测试分开。
- [ccusage](https://github.com/ccusage/ccusage)：多宿主本地日志适配、缓存和会话统计。会话用量不等同于某一 MCP 的独占用量。
- [Anthropic skill-creator](https://claude.com/resources/articles/improving-skill-creator-test-measure-and-refine-agent-skills)：触发测试、有无 Skill 对照、结果验收和耗时 / token 测量。
- [Snyk Agent Scan](https://github.com/snyk/agent-scan)：风险分类与证据展示。其远程分析会发送部分配置与 Skill 内容；不能在 thermo 中默认接入上传。

外部资料于 2026-10-17 核对；本页不表示已实测这些项目的运行表现。
