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

MCP 当前只做配置检查；界面和 JSON 都明确标记其定义、连接耗时和调用表现尚未测量。没有发现配置问题不表示实际可用。

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
