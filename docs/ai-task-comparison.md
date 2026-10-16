# MCP / Skill 任务对照

`thermo agents compare FILE [--json]` 比较本地 JSON 中的两组任务记录。命令只读取指定文件，不运行任务、模型、工具或验收脚本，不从普通会话日志推测任务成功。

```sh
thermo agents compare docs/examples/task-comparison.json
thermo agents compare /path/to/measured-records.json --json
```

仓库示例的 `evidenceKind` 是 `synthetic`，用于演示计算和回归，不能证明任何 Skill 提高了效果。真实采集填写 `measured`；这也是采集方的声明，Thermo 不认证原始结果。

## 采集与配对

在测试前固定任务、输入、验收条件、模型版本和参数。每次运行使用干净会话，恢复相同初始环境，交替安排 baseline / candidate，保留失败、超时、中断和未验收的运行。任务中途改变提示词或验收条件后，应重新采集一组记录。不要只选择做成功的任务。

`kind` 填 `skill` 或 `mcp`。`baselineRevision` 与 `candidateRevision` 填对应版本完整内容的 SHA-256；无 Skill / MCP 的基线可填 `none`。MCP 应同时固定服务版本、工具定义和相关配置；Skill 应包含实际使用的正文及依赖资源。哈希中不要遗漏会影响任务的资源，也不要收录凭据。

每次运行包含：

| 字段 | 内容 |
|---|---|
| `taskID` / `repetition` / `variant` | 任务标识、重复编号、`baseline` 或 `candidate`；三者唯一 |
| `conditions.model` | 精确的模型标识；不填浮动别名 |
| `conditions.environment` | 环境快照的 SHA-256，覆盖输入、依赖、主机和初始状态 |
| `conditions.settings` | 宿主版本、模型参数、上下文、工具权限等固定设置的 SHA-256；本次比较的 Skill / MCP 差异放在 revision 中 |
| `conditions.task` | 完整任务及输入的 SHA-256 |
| `conditions.verifier` | 预先固定的验收方法及版本的 SHA-256 |
| `outcome` | `passed`、`failed`、`timeout`、`error`、`unverified` |
| `seconds` | 整次任务经过时间；包括重试和工具调用。未知省略或填 null |
| `inputTokens` / `outputTokens` | 整次任务的原生请求计数；未知省略或填 null，不填估算值，不分摊给单个工具 |
| `tokenSemantics` | 计数来源、版本和缓存处理口径的固定标识；提供 token 时必填 |

同一个文件的模型、环境和设置必须一致，否则拒绝比较。任务和验收方法可随任务不同，但每个配对必须完全相同，同一任务 ID 的可比较重复也必须保持相同任务与验收哈希。哈希均为 64 位小写十六进制；标识只接受字母、数字、点、冒号、下划线和连字符，最多 128 字节。文件最多 4 MiB、10,000 条运行；重复编号为 1–1,000,000，时间为 0–31,536,000 秒，单项 token 为 0–10¹²。

记录只需包含标识、哈希和指标。原始提示词、结果、截图及验收证据留在采集方自己的受控目录，便于复查。不要把它们或凭据写进标识；命令不会读取哈希指向的文件，也不会执行 JSON 里出现的额外字段。

## 结果解释

按 `taskID + repetition` 配对。重复结果直接拒绝；缺少一方或任务 / 验收哈希不一致时列入 `excluded`，不混入可比较结果。报告保留输入总条数、匹配数量、排除原因及双方结果分布。排除过多时，应修复采集方法，而不是据剩余样本判断优劣。

通过率只使用双方都已验收的配对。`failed`、`timeout`、`error` 均不算通过；`unverified` 不被猜成失败。报告列出双方都通过、仅候选通过、仅基线通过和双方都未通过的数量，以及候选减基线的通过率百分点差。

时间与 token 单独报告配对差值的中位数、最小值、最大值及样本数。正数表示候选消耗更多，负数表示更少。时间包含双方都提供计时的失败、超时和未验收运行，不能当作“完成任务所需时间”；要结合结果分布看。token 还要求双方口径完全相同，口径不符另计数量，不混入差值。没有两侧计量的样本不会按零处理。

示例有 3 对合成记录：双方通过 1 对、各有 1 对仅自己通过，通过率差 0 个百分点；任务时间差中位数为 +2 秒。token 只有 2 对可比，输入差中位数 +35、输出差中位数 −15。这个例子同时说明“输出更少”并不代表“整体更好”。

当前只做描述性比较，不提供显著性、综合质量分、自动卸载建议或跨工具排名。汇总按配对计权，重复更多的任务权重更大；报告同时列出任务数，评测应预先统一每项任务的重复次数。任务数量、覆盖面和采集偏差仍需人工评审；`measured` 不代表结果已由 Thermo 独立验真。App 尚未接入该评测入口。

方法参考 [Anthropic 的 Skill 评测说明](https://claude.com/resources/articles/improving-skill-creator-test-measure-and-refine-agent-skills)：固定任务，比较有无 Skill 或不同版本，分别记录验收、耗时和 token。外部资料于 2026-10-17 核对。

[验收记录](measurements/task-comparison-2026-10-17.json)包含 41 项相关 Swift 测试、7 项编译后 CLI 检查及二进制 / 夹具哈希。`python3 scripts/verify-task-comparison.py .build/debug/thermo` 可重复验证结果计算、未知值、条件不符、重复记录、内容不执行和管道输入拒绝；范围为本地 Debug CLI 与合成数据，不包含实际模型任务、App 或发布安装。
