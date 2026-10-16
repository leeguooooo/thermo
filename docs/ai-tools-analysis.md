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
