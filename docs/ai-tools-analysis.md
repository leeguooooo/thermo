# AI 工具分析

thermo 的 AI 工具页需要回答：配置是否有故障、定义有多大、实际调用是否顺畅，以及 MCP / Skill 是否帮助完成任务。这四项需要不同证据。

## 已实现的静态 Skill 检查

`thermo agents context [--agent AGENT] [--json]` 只读取配置与 Skill 文件，不启动 MCP，不执行工具，不读取会话正文。按完整 SKILL.md 的估算 token 排名，输出目录描述、正文和完整文档的独立测量。App 的 Skills 分类显示最大的五项；逐项清单显示占用。

- 字节、字符和行数来自原始文本，输出不包含正文。
- token 是 `ascii4-unicode1-v1` 启发式估算：每四个 ASCII 标量计一个 token，每个其他 Unicode 标量计一个 token。它不代表任何模型的分词结果或账单。
- 目录项由 name 和完整 description 构成，完整文档含 front matter。两者不能相加当作实际加载量。未读取引用文件。
- 递归检查独立 Skill，找到 SKILL.md 后不继续把其 scripts / references 当作独立 Skill。包含 Codex 的 `.system` 目录。
- 每个文件最多读取 1 MiB，扫描最多处理 10,000 个目录节点、深度 16。无法读取、循环链接或达到上限会报告不完整；统计只覆盖成功读取的文件。
- 同一真实路径的别名保留为安装条目，不报成同名冲突。跨目录的不同同名 Skill 分别挂上冲突提示。插件命名空间不参与普通 Skill 的同名判断。
- 嵌套条目不提供删除操作，避免沿合集链接移除共享目标。

当前范围不包含项目级 Skill 和 Codex 插件目录；条目数也可能包含同一文件的多个别名。该范围同时显示在 App、CLI 和 JSON 中。

## MCP 主动检查

普通体检仍只检查配置，不启动任何 MCP。`thermo agents inspect NAME [--agent AGENT] [--timeout SECONDS] [--json]` 或 App 的“连接并检查”会显式启动选定的 stdio 服务，执行 initialize、notifications/initialized 和完整分页 tools/list，不调用业务工具。不改写配置，也不连接其他已运行的服务实例。

结果分别给出启动、握手、列表和总耗时，以及服务 instructions、完整工具定义数组、逐工具描述、输入 / 输出 schema 和 annotations 的静态占用。完整定义用排序键的紧凑 JSON 测量，正文不导出；工具名称脱敏，服务返回的错误正文不回显。分项估算不保证相加等于完整 JSON 的估算；未测量宿主的包装、延迟加载或缓存。

- 当前支持 stdio 与 2024-11-05、2025-03-26、2025-06-18 协议版本。HTTP 明确返回 unsupported，不显示为空清单或正常。
- 默认总时限 10 秒，最大 120 秒。采用单调时钟，所有读写非阻塞；超时、取消、协议错误、断流和大小上限返回未完成。
- 单条待解析消息最多 8 MiB，整个连接最多接收 16 MiB；最多 100 页、10,000 个工具。重复或无效游标拒绝作为完整清单。
- 不向服务声明 sampling、elicitation 或 roots 能力；只响应 ping，其他服务发起的请求返回不支持。
- 关闭自己启动的子进程：先关 stdin，短暂等待，再依次 TERM / KILL；不会结束用户已经运行的 MCP 实例。
- 缺失描述、缺失 / 非对象输入 schema、错误 schema type 和重复工具名给出具体提示。它们是定义问题，不能直接推断任务成功率。

本机 CodeGraph 已完成一次真实握手和完整工具列表读取，见 [测量记录](measurements/mcp-codegraph-2026-10-17.json)。这次未调用 codegraph_explore，不代表业务调用已验收。App 当前通过编译，检查结果页已完成[中文原生离屏渲染检查](measurements/mcp-inspection-zh-2026-10-17.png)；这不是已安装 App 中点击与取消的实际验收。

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
