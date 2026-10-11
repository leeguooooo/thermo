# thermo

macOS 温度 / 风扇 / 功耗监控与风扇控制。命令行 + 菜单栏 App，支持 Intel 与 Apple Silicon，macOS 13+。

```
$ thermo
thermo · MacBookPro16,1 · 08:47:18

Temperatures
  CPU       73.4°C  █████████░░░  avg 71.9°C    18.3 W
  GPU       62.9°C  ████████░░░░  avg 51.4°C     0.4 W
  ...
Fans
  0 Fan 1     5617 rpm  ████████████ 100%  [1836–5616]  auto
  1 Fan 2     5205 rpm  ████████████ 100%  [1700–5200]  auto
```

## 构建

```sh
make            # = scripts/build.sh：release 构建 + 打包 dist/Thermo.app + ad-hoc 签名
make test       # 单元测试（含一个真机 SMC 测试，无 SMC 时自动跳过）
make install    # CLI 装到 /usr/local/bin，App 拷到 /Applications
```

### 正式签名与公证（Apple 开发者账号）

本机已配置好（团队 6ZPXG4KVVS）：

```sh
make release
# 等价于：
SIGN_ID="Developer ID Application: LI GUO (6ZPXG4KVVS)" NOTARY_PROFILE=thermo \
NOTARY_KEYCHAIN=$HOME/Library/Keychains/login.keychain-db scripts/build.sh
# 产物：dist/Thermo.app（已 staple）、dist/Thermo-<ver>.zip、dist/thermo-cli-<ver>.zip
# 通用二进制：再加 ARCHS="arm64 x86_64"
```

新机器上的一次性准备：从钥匙串导入 Developer ID Application 证书（.p12），再保存公证凭据：

```sh
xcrun notarytool store-credentials thermo --key AuthKey_XXXX.p8 --key-id XXXX \
  --issuer <App Store Connect Issuer ID> --keychain ~/Library/Keychains/login.keychain-db
```

`thermo helper status` 会显示当前二进制的签名团队。用 Developer ID 签名后：

- **helper 只接受同一 Team ID 签名的客户端**（运行时从自身签名读取 Team ID，无需配置）。ad-hoc 构建只校验标识符 `dev.thermo.cli` / `dev.thermo.app`，任何本地程序都能伪造——但最坏结果也只是风扇转速被设到 min–max 范围内，超温保护仍然有效。
- **App 通过 `SMAppService.daemon` 注册 helper**，用户在「系统设置 → 通用 → 登录项」中批准；ad-hoc 构建则弹管理员密码框安装到 `/Library/PrivilegedHelperTools`。

## 发布

见 [RELEASING.md](RELEASING.md)：`make release APPCAST_URL=…` 产出已公证的 DMG、zip 和 Sparkle appcast。

## 卸载

1. Thermo → 设置 → Fan helper → Uninstall（或 `thermo helper uninstall`），风扇恢复自动。
2. 删除 `/Applications/Thermo.app`、`/usr/local/bin/thermo*`。
3. 可选：`rm -rf ~/Library/Caches/dev.thermo && defaults delete dev.thermo.app`。

## App 操作

主窗口用 `⌘1`–`⌘6` 切换概览、传感器、风扇、浏览器页面、磁盘清理和 AI 诊断，`⌘,` 打开设置。传感器页用 `⌘F` 搜索名称、分组或 SMC key；“包含未命名传感器”可以查看未识别名称的读数，离开该页后恢复常规采样。

概览里的 CPU 负载按每核负载显示：`1.0×` 表示平均每核有一个任务运行或等待，数值可以超过 `1.0×`。它与 CPU 使用率不同。温度图跟随摄氏度/华氏度设置，并自动扩展范围以显示高温读数。

内存、进程占用和交换空间使用 MiB / GiB（二进制单位）；磁盘容量和清理大小使用 MB / GB（十进制单位）。JSON 保留既有数值字段：`memoryKB` 使用 KiB，`swapUsedMB`、`heapMB` 使用 MiB，数值不变。

## CLI

| 命令 | 说明 |
|---|---|
| `thermo` | 概览：各组最高温度、风扇、功率、电池 |
| `thermo temps [--all]` | 全部温度传感器（`--all` 含未命名的） |
| `thermo fans` / `power` / `battery` | 风扇 / 功率·电压·电流 / 电池 |
| `thermo watch [-i 1] [-n N]` | 全屏实时视图（1-3 / ←→ 切页，q 退出）；非 TTY 或 `--json`/`--csv` 时逐行输出，便于记录 |
| `thermo list` / `thermo get KEY…` | 原始 SMC key |
| `thermo fan set 0\|all 3000\|max` | 固定转速 |
| `thermo fan curve all 50:min,70:3000,85:max --sensor cpu` | 温度曲线（线性插值，cpu/gpu/max） |
| `thermo fan auto [id\|all]` / `fan status` | 恢复自动 / 查看策略 |
| `thermo helper install\|uninstall\|status` | 管理特权 helper |
| `thermo bench` | 采样延迟基准 |
| `thermo agents fix [NAME] [--dry-run] [--yes]` | 自动修复：先列出每一步要执行的命令再确认。优先调用 agent 自带的命令（`claude mcp remove`、`claude plugin uninstall`、`codex mcp remove`）；改配置前备份到 `~/Library/Application Support/Thermo/Backups`；文件移到废纸篓；结束进程前复核命令行；每步记录到 `~/Library/Logs/Thermo/fix.log` |
| `thermo agents list [AREA]` | 列出检查过的每一项（hooks / mcp / plugins / skills / statusline / launchd / processes），逐项标 ✓ 正常、! 警告、✗ 错误、- 已关闭；App 的 Agents 标签页和「Open Report」窗口显示同一份清单 |
| `thermo agents [--all] [--json]` | AI agent 诊断：Claude Code / Codex / Cursor / Gemini 的 hooks、MCP server、插件、skills、状态栏，以及 launchd 重启风暴、泄漏/跑着已删除二进制的进程、明文凭据（只读，输出已脱敏；有 error 时退出码 1） |
| `thermo clean [ai\|CATEGORY]` | 列出可清理的内容，只读不删 |
| `thermo clean run safe\|ID…` | 清理指定项（先确认；`--yes` 跳过确认，`--trash` / `--permanent` 指定处理方式） |
| `thermo clean log` | 历次清理删了什么 |

所有读取命令都支持 `--json`、`--csv`，另有 `--fahrenheit`、`--no-color`（也遵循 `NO_COLOR`）。

电池 CSV 和汇总 CSV 使用 `kind,key,name,group,value` 列；电池字段的 key 标明单位，例如 `temperature_c`、`current_a`、`health_percent`。缺失读数不输出，充电和外接电源状态使用 0/1。CSV 温度始终以摄氏度输出。

`get --csv` 使用 `key,type,value,hex,error` 列。单个 key 读取失败时保留错误行，其他 key 继续读取；命令最终返回非零退出码。

`fan status --csv` 输出转速、范围、手动模式和 helper 策略；`policies_available=false` 时策略为 `unknown`。`helper status` 的 JSON/CSV 包含 `installationSource`：`legacy` 表示发现旧式安装文件，`connected` 表示已连接到后台 helper，`unknown` 表示无法确认后台注册；此时 `installed=false` 只表示未检测到安装。

`bench --json/--csv` 导出每次操作的平均 wall/CPU 毫秒、重复次数、最后一次采样返回的记录数和 CPU 开销估算。采样测试包含温度、风扇、功率、电压、电流；估算不是整个 App 的实际 CPU 占用。SMC 传感器数量单独记录，返回记录数包含 IOHID 和风扇，也不等于 SMC 调用次数。

诊断 JSON 中的敏感参数使用占位符，敏感项目标识改为稳定的匿名 ID。通过 CLI 或界面定位项目后执行修复，内部仍使用原始参数和进程身份校验。

诊断页提供「停止检查」。停止期间显示进度，检查退出后保留上次完整报告；点击「重新检查」可刷新。停止按钮只作用于只读检查，已确认的修复步骤继续执行。

`agents`、`agents list`、`agents show NAME` 支持 CSV。`kind=item` 为项目，`kind=finding` 为总体说明；`findings` 和 `actions` 列保留脱敏后的 JSON，`generated` 标明本次检查时间。

退出或重启程序后，Thermo 会等待 5 秒复查：目标是否仍在运行、内存占用是否下降、系统内存压力和温度压力是否变化。复查会包含空闲程序，避免把刚重启后 CPU 很低的 App 当成“没有重新打开”。短时占用下降不等于整机已经变快；交换内存和平均负载可能延迟变化。

`pulse --csv` 和 `pulse history --csv` 使用 `kind,name,value,unit` 列，温度为 °C，交换内存为 MiB；风扇、进程和历史归因记录的 `value` 为脱敏后的 JSON，保留其明细。

浏览器页面支持查看所有标签页、搜索、多选以及「选择推荐候选」。重复地址和两次采样间的增长会给出理由；高占用本身不会被推荐关闭，窗口当前页也不会被自动选中。确认清单后，按标签页唯一 ID 关闭，已变化或刚切换到的页面会跳过。5 秒后复查浏览器占用、内存压力、温度压力和平均负载；旧的逐页测量值会明确标记。未保存输入、固定标签页和音频状态不会读取，需要用户自己核对。

`pulse chrome --json/--csv` 保留浏览器模式、提示和测量报告。无法读取浏览器时仍输出结构化结果，并返回退出码 1；CSV 的嵌套报告使用 `JSON` 单位标记。

历史查询的 `--since` 接受正数小时、`h` 或 `m` 后缀，统一最多查询 24 小时；零、负数和非有限值会返回参数错误。

浏览器增长比较要求两次样本属于同一 URL 和文档；跳转、重载或缺少可比旧样本时保留当前读数，注明未评估增长。旧格式没有文档导航时间时仅按 URL 比较，监听器增长提示也是排查线索。

`settings` 的全部查询、单项查询和写入结果都支持 JSON/CSV。JSON 使用设置名到字符串值的映射，CSV 使用 `key,value` 两列，例如 `thermo settings interval --json`。

菜单栏、概览、温度告警和 CLI 的“最高温度”取已命名传感器中的最高有效读数，包含存储、主板等分组。风扇曲线的 `max` 和过热安全保护仍以 CPU/GPU 温度为准。

`thermo settings slowdown-alerts on|off` 和 `thermo settings unnamed-sensors on|off` 与 App 使用同一组开关。`--yes` 等标志不接受 `=false`；需要确认时省略 `--yes`。

## 磁盘清理

`thermo clean` 和 App 的 **Disk** 页。常规清理（开发缓存、Xcode、浏览器、日志、旧安装包）之外，重点放在 AI 工具留在磁盘上的东西：

- **AI 会话**：Claude Code、Codex、Gemini CLI 的会话按项目归组，标签取会话里记录的 `cwd`，标题取第一条提问或 Codex 线程名；Cline / Roo / Kilo 任务；Cursor、VS Code、Windsurf 里已删除项目的聊天和工作区数据。超过 `--older-than`（默认 30 天）没动过的会话，或所属项目文件夹已经删了的会话，才会被选中。
- **AI 工具残留**：Claude Code 自动更新留下的旧版本、插件旧版本、`/private/tmp/claude-*` 里已结束会话的临时目录、已删会话的 file-history / todos、Claude 桌面版和 Cursor 等的缓存、给 agent 用的 Playwright 浏览器。
- **模型**：Ollama 每个模型单独一项，和其他模型共用的层不删；Hugging Face 缓存按仓库列出；LM Studio、Whisper、PyTorch Hub、GPT4All、Jan 等。
- **项目构建产物**：按标志文件识别（`package.json` → `node_modules`、`Cargo.toml` → `target`、`Package.swift` → `.build` 等），默认在 `~/Developer`、`~/code`、`~/github.com` 这类目录下找，`--root` 可以指定。
  指定 `--root` 时仅扫描指定目录。Git 已跟踪的产物会保留；正在运行 agent 的项目会阻止清理。项目发现与目录统计同时进行，页面逐项显示结果。

  `thermo clean projects --root ~/github.com,~/tk.com --stream` 会输出逐行 JSON：`started`（磁盘剩余空间）、`items`、`progress`、`finished`（完整报告）。`thermo clean overview --stream` 同样支持逐项输出。只收到部分事件时，扫描还未完成；普通 `--json` 的完整报告格式保持不变。
  总览单独显示项目与源代码目录，按仓库列出整体占用；它包含源码，不能当作全部可释放空间。点击“扫描构建产物”进入项目分类，再选择具体产物。Xcode、开发缓存和临时文件也有对应扫描入口，按钮不直接执行删除。项目根目录会去掉重复别名、嵌套根目录和指向整个 home 的别名；其他磁盘上的项目不计入当前磁盘容量。
  空间总览可复用 CLI 的完整缓存，并按 App 当前语言显示分类标题；切换语言只更新文字，保留原扫描日期和大小。路径保护同时核对父目录符号链接解析后的实际位置，避免缓存或项目别名指向文稿、凭据或用户目录以外的内容。
  空间总览按子目录增量更新。流式 `entry` 的 `id` 在分类内保持不变，调用方应替换该分类的旧条目；`complete`、`measuredLocations`、`totalLocations` 标明分类进度。未完成分类显示“至少”多少空间，`finished` 事件返回扫描结束时的最终状态。扫描最多四个工作线程，页面更新会合并，避免大量临时文件造成任务和界面更新堆积。
  给 agent 限时获取结果可用 `thermo clean overview --budget 10 --stream`，或 `thermo clean projects --budget 10 --json`。预算到期后在下一处取消检查停止，结果标记 `cancelled: true`，仅统计已完整测量的目录；未完成分类标注 `complete: false`，大小是下限，不替换已有完整报告。`--budget` 只用于扫描，不能用于执行清理。
  完成的报告按分类、项目目录、保留天数和语言分别缓存，最多保留 32 个范围。再次打开分类页面或执行清理时，只复用范围一致且未过期的报告；清理后所有旧计划失效。项目活动读取会校验文件身份和修改时间，未变化的 Codex 会话无需反复打开。
  `thermo clean run projects --dry-run --json` 只返回清理计划，不删除文件、不执行清理命令，即使加了 `--yes` 也如此。真实执行前会复查应用、构建进程和正在运行的可执行文件。模拟器移除会永久删除，由确认框明确说明；`--trash` 不会执行这种操作。设备 ID 固定在扫描结果里，执行前再检查当前状态；旧的 `delete unavailable` 批量命令必须重新扫描。
  清理结果分别显示已删除文件的估计大小、移入废纸篓的大小，以及磁盘可用空间的前后实测变化。JSON 结果保留原有数组格式，每项新增 `spaceObservation`（`before`、`after`、`availableChangeBytes`）；差值包含同时发生的其他磁盘活动，不能全部归因于清理。清理后旧空间总览失效，页面容量条直接读取当前可用空间，无需等待文件扫描。




安全规则：

- 扫描只读。`clean run` 先列出计划，再要求确认。
- **Agent 工作树**：`thermo clean worktrees` 单独扫描 agent 留在仓库里的 checkout；`thermo clean sessions` 只扫描会话记录，避免等待整个项目目录遍历。`thermo clean ai` 仍会包含两类。工作树的未提交改动、运行中的 agent 和近期写入检查仍会阻止误删。
- 每项都有级别。`safe` 是会自动重建的缓存，直接删除；`review` 是会话、模型这类数据，移到废纸篓；`risky` 是有未提交改动的 worktree，`safe` / `all` 都不会选中它，必须写出完整 id。
- 正在运行的 Claude Code 会话、2 小时内写过的会话、正在运行的 agent 所在目录、所属 App 还开着的缓存，一律跳过。
- 删除前逐条复查路径：家目录以外的路径、`~/Documents`、`~/.ssh`、`.git`、Claude 的 `memory/` 这类位置永远不删。只移除列出的路径，不跟随符号链接。
- 每次删除都写进 `~/Library/Logs/Thermo/clean.log`。
- 尊重 Claude Code 自己的 `cleanupPeriodDays`，报告里会显示这个值。Codex 的线程索引存在 SQLite 里，Thermo 不改它，所以删掉会话后 Codex 列表里可能还会留着标题。

清理只以当前用户身份运行，root helper 不链接 CleanKit。

## 风扇控制安全机制

- 只有 root helper（`dev.thermo.helper`）写 SMC；转速始终限制在 SMC 报告的 min–max 内。
- 策略由 helper 持有，CLI/App 退出后仍然生效；helper **启动、退出（SIGTERM/SIGINT/SIGHUP）时把所有风扇恢复自动**。
- 超温保护：最热的 CPU/GPU 传感器连续 2 次采样（4 秒）达到阈值（Intel 95 °C，Apple Silicon 110 °C——实测 M4 在系统自己控风扇时核心常驻 103–115 °C）就全部恢复自动；策略**暂停而不清除**，降到阈值 −10 °C 以下并保持 60 秒后自动恢复。
- 降速每 2 秒最多降 400 rpm，变化 < 50 rpm 不写入，避免风扇来回抖动。
- 未测试：Apple Silicon 的写入路径（`Ftst` 解锁 + `F<i>Md`/`F<i>Tg`）需要在 M 系列机器上验证。

## 性能

实测（MacBookPro16,1，i9-9880H，T2）：

| | 墙钟 | CPU |
|---|---|---|
| `thermo --version` 冷启动 | ~11 ms | |
| `thermo fans` 冷启动 | ~20 ms | |
| `thermo` 概览冷启动 | ~35 ms | |
| 采样 essential（23 key） | 8.5 ms | 3.2 ms |
| 采样 known（72 key） | 26 ms | 9.9 ms |
| 菜单栏 App 后台 | | **0.18 % 单核** |

T2 机型上每次 SMC 读取约 370 µs（经 T2 转发、串行，多线程无收益），所以优化集中在**少读 key**：

- 一次 SMC 连接；C 层开放寻址表缓存 key 信息，每次读取只有 1 次 IOKit 调用。
- 发现结果按机型 + key 数量缓存到 `~/Library/Caches/dev.thermo/`（字节级解析的文本格式），冷启动跳过 1164 个 key 的扫描（~530 ms）。
- 分层采样：`essential`（每组代表传感器）/ `known` / `all`；每个命令只读自己需要的部分；风扇 min/max 30 秒刷新一次。
- App：面板关闭时只读 CPU/GPU + 风扇，数据不进入 SwiftUI；标题文本不变时不重绘。

在 Mac15,3 上，`thermo bench` 连续 100 次采样的均值：

| 采样层级 | 墙钟 | CPU |
|---|---:|---:|
| essential | 8.94 ms | 0.57 ms |
| known | 57.62 ms | 1.89 ms |
| all | 94.59 ms | 3.30 ms |

这个基准包含温度、风扇、功率和电气读数，用于比较采样层级，不是 App 的总 CPU 用量。菜单栏默认 CPU 指标仍使用 essential；选择最高温度或启用过热提醒后，后台使用与打开窗口一致的 known 范围，避免漏掉其他已识别温度组。

## 结构

```
Sources/CSMC/        C：AppleSMC 用户客户端、类型编解码、key 信息缓存、IOHID 温度（Apple Silicon）
Sources/ThermoKit/   传感器发现/命名/分组、Sampler、电池、风扇曲线与策略引擎、XPC 协议、helper 安装
Sources/CleanKit/    磁盘清理：规则、AI 会话/模型/工具识别、项目产物、扫描与删除（不进 helper）
Sources/thermo/      CLI
Sources/ThermoHelper/ root helper（LaunchDaemon + XPC）
Sources/ThermoApp/   菜单栏 App（AppKit + SwiftUI + Swift Charts）
```

调试：`Thermo.app/Contents/MacOS/Thermo --render-preview DIR` 把面板各页渲染为 PNG（AppKit 原生控件会显示为占位块）。helper 日志：`/var/log/dev.thermo.helper.log`。
