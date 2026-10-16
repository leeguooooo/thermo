# 诊断摘要 Skill 试测

这里的 Skill 是评测候选，不会安装到用户的 Skill 目录，也不参与 Thermo 的自动体检。任务输入是虚构的诊断记录；实际模型运行与计量是真实的。

显式运行会启动 6 个独立 Codex 会话，使用当前固定的 `gpt-6.1-sol`、medium、Codex CLI 0.163.0。输出目录必须不存在，不覆盖旧结果，不自动重试：

```sh
python3 scripts/collect-ai-diagnostics-eval.py /tmp/thermo-eval-new-output
```

每项任务同时启动带 Skill 和不带 Skill 的会话，各使用独立 Home 和 Git 项目、只读沙箱，不加载用户配置。现有认证仅复制到权限受限的临时目录，进程退出后删除这份副本；原认证不改写。原始运行目录含本机运行元数据，不应整体上传或提交。

不调用模型的回归：

```sh
python3 scripts/test-ai-diagnostics-eval.py
```

8 项检查覆盖逐字段验收、JSON 结构、未知值、布尔与数字区分，以及用本地假进程验证的 token 采集、超时保留部分事件和认证副本清理。它们不代表真实模型效果测试。

## 第一轮实际结果

[审阅页](../../docs/measurements/ai-diagnostics-live-2026-10-17/review.html)保留每项任务的输出和逐字段评分。[原生计量及限制](../../docs/measurements/ai-diagnostics-live-2026-10-17/manifest.json)、[Thermo 对照记录](../../docs/measurements/ai-diagnostics-live-2026-10-17/comparison.json)和[输入记录](../../docs/measurements/ai-diagnostics-live-2026-10-17/records.json)可直接复查。

| 预设验收结果 | 带 Skill | 基线 |
|---|---:|---:|
| 整项任务所有字段通过 | 2 / 3 | 1 / 3 |
| 字段级断言通过 | 26 / 27 | 25 / 27 |
| 完成的模型运行 | 3 | 3 |

三对记录的候选减基线：输入 token 差中位数 +420，输出 token 差中位数 −79，经过时间差中位数约 −1.79 秒。各次原生 cached_input_tokens 都为 12,288；不把缓存再加到输入，也不将这些请求计数解释成账单。时间包括 CLI 启动与请求等待，排除准备夹具的时间。

这一轮不作优劣结论。只有三项微型任务，每项仅一次，且同时执行；缓存和调度会影响耗时。工具定义那项两组都通过，不能区分 Skill 效果。未连接那项出现一组差异，但没有重复样本。

未完成检查那项两组都把缺少结果的调用也计入 `unknownErrorCalls`，与预设验收规则不符。公共题目没有明确说这个字段只计“已有结果但状态未知”的调用，因此既可能是指令未讲清，也可能是评分规则过严；原始评分完整保留，没有事后改分或删除这项。下一轮应先澄清公共任务定义，并使用新的任务版本。

候选通过 `$ai-diagnostics-evidence` 显式调用，项目目录中也只有候选组放置 Skill。但六次事件流都没有 shell 读文件记录，所以 `skillReadCommandObserved: false` 只能说明未观察到该命令，不能证明宿主没有加载 Skill，也不足以独立证明正文已送入模型。第一轮不能用于推断隐式触发率或稳定的 Skill 净收益。

`skill-creator` 生成的 benchmark 中 `pass_rate` 是字段级断言比例；Thermo 的通过率要求整项任务全部通过。两者分母不同，不能混为一个成功率。审阅页先展示原始输出和评分，候选 Skill 暂未根据这次结果改写。

第一轮的采集器、Skill、题目及预期结果均已冻结并记录哈希。第一轮 verifier 字段仅哈希原采集器；预期答案另由 manifest 固定。当前采集器已把预期答案纳入未来记录的 verifier 哈希，并保留超时前的原始输出；这些改动没有重跑模型，也没有改写第一轮结果。

方法参考 [OpenAI 的 Skill 评测说明](https://developers.openai.com/blog/eval-skills)和[显式 Skill 调用及加载规则](https://learn.chatgpt.com/docs/build-skills)。审阅页由本机 skill-creator 自带生成器生成，没有启动常驻服务。
