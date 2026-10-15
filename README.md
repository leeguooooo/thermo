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

## 安装

CLI（正式签名双架构二进制）：

```sh
curl -fsSL https://thermo-updates.pages.dev/install.sh | sh
```

默认安装到 `~/.local/bin`，同时提供 `thermo-use` 别名，不会自动安装或重启 root 风扇 helper。App 请下载[正式 DMG](https://app.leeguoo.com/thermo/download)，已有 App 可通过自动更新升级。

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

1. 用 Thermo → 设置 → Fan helper → Uninstall 移除 helper；旧式管理员安装也可运行 `thermo helper uninstall`。卸载先清空并保存风扇策略，确认自动控制和 Thermo 保存的休眠设置已恢复，再移除服务。helper 必须支持协议 4，旧版或无法连接时会停止并提示先更新；CLI 不负责注销 App 的后台项目。
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
| `thermo clean whitelist [add\|remove PATH…]` | 始终保留的路径或 glob（`~/Library/Application Support/Thermo/whitelist`，每行一个，`#` 注释）；所有清理、卸载和移到废纸篓都会跳过，文件不可信时拒绝清理；`--json` |
| `thermo history [show ID]` | Thermo 做过的每项改动（清理、卸载、agent 修复、Claude 重置、隐私设置、标签、归档、退出程序），最新的在前，并写明在哪里撤销；记录在 `~/Library/Application Support/Thermo/operations.jsonl`；`--limit N`、`--json` |
| `thermo awake [status\|on\|off]` | 笔记本合盖不休眠（经辅助程序切换 `pmset disablesleep`）；温度接近风扇安全上限、使用电池且电量降到 20%、或读不到温度时自动关闭，关闭和辅助程序重启时恢复你原来的设置；`--json` |

所有读取命令都支持 `--json`、`--csv`，另有 `--fahrenheit`、`--no-color`（也遵循 `NO_COLOR`）。

电池 CSV 和汇总 CSV 使用 `kind,key,name,group,value` 列；电池字段的 key 标明单位，例如 `temperature_c`、`current_a`、`health_percent`。缺失读数不输出，充电和外接电源状态使用 0/1。CSV 温度始终以摄氏度输出。

`get --csv` 使用 `key,type,value,hex,error` 列。单个 key 读取失败时保留错误行，其他 key 继续读取；命令最终返回非零退出码。

`fan status --csv` 输出转速、范围、手动模式和 helper 策略；`policies_available=false` 时策略为 `unknown`。`helper status` 的 JSON/CSV 包含 `installationSource`：`legacy` 表示发现旧式安装文件，`connected` 表示已连接到后台 helper，`unknown` 表示无法确认后台注册；此时 `installed=false` 只表示未检测到安装。

协议 5 的 `fan status --json` 另含 `controlState`，区分已设策略、最近一次寄存器核对、核对时间、温度保护暂停和控制错误。CSV 增加 `verification_state,last_observed_mode,verified_target_rpm,checked_at,policies_suspended,suspension_reason,control_failure`；时间为 UTC ISO 8601。`policies_available` 只表示能读到已设策略，不表示硬件已执行。旧 helper 的硬件核对显示不可用。App 同样分开展示已设策略和上次核对；读回结果是历史观察，实际转速另外显示，不能把它当作当前控制权或转速保证。

新旧格式的策略回复都会检查风扇编号和策略数值，非法回复会报错，不能作为有效控制状态使用，也不会回落为自动。

风扇保护要求有效的已命名 CPU 温度，不用电池、主板或 0°C 代替。helper 清单中的必需 GPU 来源，以及本次运行中曾读到的 GPU 温度，也不能在恢复判断中无故消失。必需温度缺失时立即暂停非全速策略并尝试自动控制；恢复后默认需连续 60 秒低于恢复阈值，失联或回温会重置计时。曲线所选传感器缺失时转回自动，全速散热可继续。`controlState.suspensionReason` 和 CSV 的 `suspension_reason` 区分 `thermal` 与 `temperatureUnavailable`；合盖保护共享这套温度有效性检查。当所有风扇实际交回自动时，会尝试释放 Apple Silicon 的全局手动解锁并读回确认。

实时风扇模式可为手动、自动或未知。存在模式键和强制位时，两者都读到且解除强制才确认自动；任一有效标志表明手动就保留手动，其余不完整或异常读数为未知。快照 JSON 中未知的 `manual` 为 `null`，CSV 为 `unknown`；旧布尔值快照仍可读取。Pulse JSON 的未知模式不输出布尔值，并以 `controlMode=unknown` 标记。读取这些输出的程序需要处理未知，不能将缺少或 `null` 当作 `false`。

转速和范围读不到时仍保留对应风扇，快照 JSON 的 `rpm/min/max` 为可空字段，CSV 留空；Pulse 缺少数值也表示未知。真实 0 RPM 仍表示已停止。范围不完整、倒置或无效时不显示负载百分比，App 禁用手动应用；控制循环请求自动，并保留已触发的温度保护和原有策略，待范围恢复有效后再按策略执行。图表在缺失样本处断开，部分风扇可读时最高转速显示 `≥` 下限，不能把未知读数当零或当成无风扇。

helper 恢复自动控制时逐扇请求并读回模式或强制位；Apple Silicon 还检查 `Ftst` 解锁位。恢复未获确认时，策略查询返回错误，后台重试恢复并暂缓应用手动策略；退出状态也反映恢复失败。

手动控制先检查转速范围，写入后读回解锁位、控制模式和目标转速；目标寄存器允许 1 RPM 的编码误差。目标不变时仍核对控制权。失败后尝试恢复所有风扇为自动，保留错误并暂停手动策略，直到再次明确修改策略。这些检查确认寄存器状态，不能证明风扇实际转速已达到目标，也不能代替真实硬件验收。策略设置的成功回复表示请求被接受，实际写入由后台执行；应继续查看 `fan status`，策略查询失败时显示未知。

手动策略先保存再提交给控制循环；保存失败时请求报错，不提交新的手动控制。请求恢复自动时，即使保存失败也继续尝试恢复；此时会报错并暂停手动策略，提示旧策略可能在重启后重新加载。应解决保存错误后再次设置策略，不能把当前自动控制等同于重启后仍会保持。

卸载准备期间会阻止新的手动控制和合盖设置请求，App 也会阻止普通退出。取消管理员授权或移除失败时，客户端尝试解除卸载准备；已经清空的旧策略不会恢复。若客户端中途崩溃或连接丢失，后台保留准备保护，需要更新或重启 helper 后重试；后台重启会结束内存中的卸载准备，真实硬件与重启竞态仍需验收。

`bench --json/--csv` 导出每次操作的平均 wall/CPU 毫秒、重复次数、最后一次采样返回的记录数和 CPU 开销估算。采样测试包含温度、风扇、功率、电压、电流；估算不是整个 App 的实际 CPU 占用。SMC 传感器数量单独记录，返回记录数包含 IOHID 和风扇，也不等于 SMC 调用次数。

诊断 JSON 中的敏感参数使用占位符，敏感项目标识改为稳定的匿名 ID。通过 CLI 或界面定位项目后执行修复，内部仍使用原始参数和进程身份校验。

诊断页提供「停止检查」。停止期间显示进度，检查退出后保留上次完整报告；点击「重新检查」可刷新。停止按钮只作用于只读检查，已确认的修复步骤继续执行。

`agents`、`agents list`、`agents show NAME` 支持 CSV。`kind=item` 为项目，`kind=finding` 为总体说明；`findings` 和 `actions` 列保留脱敏后的 JSON，`generated` 标明本次检查时间。

退出或重启程序后，Thermo 会等待 5 秒复查：目标是否仍在运行、内存占用是否下降、系统内存压力和温度压力是否变化。复查会包含空闲程序，避免把刚重启后 CPU 很低的 App 当成“没有重新打开”。短时占用下降不等于整机已经变快；交换内存和平均负载可能延迟变化。

`pulse --csv` 和 `pulse history --csv` 使用 `kind,name,value,unit` 列，温度为 °C，交换内存为 MiB；风扇、进程和历史归因记录的 `value` 为脱敏后的 JSON，保留其明细。

操作记录的 JSON（列表和 `show`）增加 `complete` 与 `issues`，区分可读范围完整、部分记录可读和读取失败。没有日志可正常表示空历史；忙碌、损坏、链接、非普通文件或超大文件不会冒充无记录。部分历史中的已知 ID 仍可查看并标注读取质量，未知 ID 在读取不完整时返回错误。App 合并重复刷新，旧读取不会覆盖恢复后的新结果；读取失败时保留已知记录并显示提示。该状态只针对保留日志的本次读取，写入仍为尽力而为。 新版 App/CLI 使用同一状态目录的内核锁协调追加与轮转，读取只在复制日志字节时持共享锁，繁忙时显式返回不完整。进程退出会释放锁；混用不参与该协调的旧版写入程序时，不能保证这项并发保护。

浏览器页默认打开「标签组」。点「预览整理方案」会按网站或自定义域名规则生成方案，确认后建立 Chrome 原生标签组。默认只整理同一窗口、同一账号中尚未分组的后台标签；已有标签组、当前页、固定页、音频页、隐私页和 agent 标签保持原样。普通网站至少有两个后台标签才建组，自定义规则可以整理单个标签。完成后可撤销本批操作，撤销时已被用户改名、移动、激活或保护的标签会跳过。

「持续自动整理新标签」默认关闭。开启后，Thermo App 运行期间每分钟检查一次并应用同一套规则；不会关闭标签，也不会跨窗口或 Chrome Profile 移动标签。需要 chrome-use 扩展 0.5.48 或更高版本。另有 Thermo 本地分类，可多选后命名；本地分类不会改写 Chrome 原生标签组。

保存完成并读回校验后才关闭。保留各窗口当前页、固定页、音频页、隐私标签、浏览器设置及 agent/调试器使用中的页面；保护信息缺失时不能批量关闭。每页关闭前再检查，关闭后核对标签是否消失。记录使用本机用户权限保存，不上传。保存的是网址、标题、顺序和 Thermo 分组，不能恢复未提交输入、网页运行状态或登录有效性。

「已保存的标签组」支持逐页查看结果、打开链接和批量恢复。默认恢复到原来的浏览器窗口，原会话结束后要明确选择目标窗口，避免打开到错误账号。已恢复页面不会再次打开，结果不明确的操作不自动重试。CLI 与 App 共用 `~/Library/Application Support/Thermo/TabWorkspace/`，并用系统锁防止同时操作。

```sh
thermo tabs list --json
thermo tabs organize --dry-run --json
thermo tabs organize --yes --json
thermo tabs auto on --yes
thermo tabs rule add github.com GitHub --color purple --yes
thermo tabs organized --json
thermo tabs undo-organize UUID --yes
thermo tabs group 调研 --ids ID,ID --yes
thermo tabs archive --group 调研 --dry-run
thermo tabs archive --group 调研 --yes
thermo tabs archive --all-windows --name 暂存 --yes
thermo tabs saved --json
thermo tabs show UUID --json
thermo tabs restore UUID --yes
thermo tabs restore UUID --window WINDOW_ID --yes
```

标签 ID 和窗口 ID 从 `tabs list` 读取；默认只操作前方窗口。`--ids`、`--group`、`--window` 可组合缩小范围。`tabs organize --dry-run` 先列出原生标签组方案，`--yes` 才执行；`tabs auto on` 开启持续整理，`tabs undo-organize` 按批次撤销。`tabs group --by-site --yes` 只调整 Thermo 本地分类。标签整理分别读取所有已连接 Chrome Profile 的保护信息，执行前使用标签所属账号的连接再次核对，不改变 chrome-use 的默认账号或 agent 会话，也不附加页面调试器。其他 Chromium 浏览器需兼容的连接，否则保持只读。

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
  扫描默认使用 60 秒的协作式预算，并持续向 stderr 输出进度（包括 `--json` 模式）；stdout 保持单份有效 JSON。`--timeout` 是 `--budget` 的别名，两者不能同时指定。大型项目和工作树使用有界的已分配空间测量，下限标为 `sizeIncomplete`，估算标为 `estimatedSize`；`--exact --budget 300` 可完整测量。严重磁盘 I/O 等待可能延迟到下一处取消检查，预算不是内核调用的硬超时。

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

## 软件管理

软件大小区分「未测量」「完整」「不完整」「无法读取」。测量成功的空目录可显示零值；权限不足、路径消失或读取错误不显示为完整的 0 B。部分已知大小显示「至少」，不确定状态会保留在 JSON、卸载预览、执行结果和历史中。旧缓存没有测量状态时不会把零当作已确认大小；未检查完整的残留数据保留在列表中，需先核实后再移除。

展开应用详情后，可点「仅审阅关联数据」保留应用本体，只把计划中列出的关联文件移入废纸篓。CLI 使用 `thermo apps uninstall NAME --data-only --dry-run --json` 预览，确认后去掉 `--dry-run`；非交互执行加 `--yes`。浏览器个人资料、聊天和邮件数据仍默认保留，白名单仍按移动路径检查；应用正在运行或审阅后身份变化时拒绝执行。`--with-data` 仍是额外的个人数据选择，不会因 `--data-only` 自动开启。选中数据可能包含设置或登录状态，如需恢复，应在重新打开应用前通过操作记录恢复。历史区分关联数据移除和应用卸载，并保留批次恢复入口。

审阅会重新测量关联文件，并读取标准应用目录和调用方已知附加应用的声明；共享或无法确认归属的路径列为保留。执行前重新核对应用清单指纹及选中路径的元数据，变化时要求重新审阅；单项计划不导出其他应用的完整清单。目录只复核选中路径本身的元数据，没有递归封存全部内容，不能消除复核与移动之间的所有窗口。已确认的应用/关联数据移除在关闭窗口后继续，正常退出需等待操作完成。

归属复核也纳入当前用户进程中可识别的目录外应用副本及嵌套 `.app` 声明。同 Bundle ID 副本存在时，按标识和名称匹配的数据都保留；移动各项前重读进程状态，新副本或目标应用临时启动时停止剩余操作。进程清单获取失败不会当作“没有运行应用”。未运行且未提供路径的目录外副本仍不能自动发现。

默认先显示所有应用的分配空间，再测量关联数据，采用 60 秒协作式预算和每个应用 20,000 个条目的发现上限；未读完的大小保留下限，可点「完整测量大小」或运行 `thermo apps --exact` 请求完整遍历。停止、超时和连续重扫共用最多四个工作线程，底层调用未返回时不会假定线程已经释放。关联目录的发现只枚举名字，不为每个条目额外请求 URL 属性。

「软件管理 → 更新」检查 Homebrew 管理的应用。首次打开使用 Homebrew 已有记录；「刷新目录并检查」先执行 `brew update`，再检查版本。App Store 更新有单独入口，其他来源的应用仍由各自更新器管理。

「其他应用」从本机声明中识别 Sparkle 更新源、App Store 收据及未声明来源的应用。发现来源不访问服务器；单项检查或确认批量检查后才请求所选 HTTPS feed。最多同时检查四项，支持停止并保留已完成结果；离开页面会取消请求并清空队列。

`thermo apps updates sources --json` 只发现本地来源；`thermo apps updates check NAME --dry-run --json` 离线预览，去掉 `--dry-run` 才检查选定 feed。导出不包含私密更新 URL 和下载地址参数。请求不使用 Cookie、钥匙串凭据、SSO 或客户端证书，TLS 由系统校验。

Sparkle 检查比较构建号，区分完整包、增量包、测试渠道、系统及声明的硬件要求。feed 限制为 2 MiB、30 秒，拒绝实体声明和超深 XML；失败或不支持的条目保留原因，不视为“所有应用都是最新版”。

有嵌入 Ed25519 公钥的应用，其已签名 ZIP 或受支持的 DMG 更新可点击「在 Thermo 中安装」。确认后重查 feed，下载至私有目录，验证归档签名、代码签名、发布者、Bundle ID、版本、构建号、目录结构和实际 Mach-O 架构，再原子替换。原生 Apple 芯片版本不会被 Intel-only 包覆盖。替换后再次核实新应用和保留副本；失败时只在对象身份未变化且备份仍有效的情况下回滚，不覆盖其他进程换入的对象。

「恢复记录」以及历史入口可恢复未再变化的已安装应用；两份版本均保留。`thermo apps updates install NAME --dry-run --json` 离线预览来源，去掉 `--dry-run` 后检查并确认安装，`--yes` 用于非交互执行。`thermo apps updates recovery --json` 查看记录，`recovery restore ID --dry-run` 预览恢复，确认后去掉 `--dry-run` 执行。记录损坏或无法读取会显示问题，不当作空历史。

当前原生安装支持 ZIP32、ZIP64 普通应用包及 UDRO/UDZO/UDBZ/ULFO/ULMO 只读 UDIF 镜像（归档最多 2 GiB、展开预算最多 8 GiB）。DMG 在私有目录只读挂载，要求没有加密或许可协议；只选择一个应用，复制校验后仅卸载该私有镜像，不强制卸载其他卷。挂载超时或无法确认卸载时保留工作目录，交由人工检查。

加密 ZIP、PKG、增量包、脚本及其他镜像格式继续使用原应用更新器。安装以当前用户运行，无权写入的应用交由原更新器处理，不向硬件辅助程序添加软件安装权限。安装及恢复期间阻止正常退出；真实第三方软件安装仍需单独验收。

`thermo apps updates --json` 输出覆盖范围、候选、跳过项与错误；`--refresh-catalog` 刷新 Homebrew 目录。`thermo apps updates apply TOKEN --dry-run` 预览单项更新，去掉 `--dry-run` 后交互确认，或用 `--yes` 执行。预览后应用、安装记录或 cask 定义变化会拒绝执行，正在运行的应用需要先退出。安装只指定该 cask，要求校验值，不强制覆盖，关闭自动清理和依赖升级，并使用 Homebrew 的 `--no-quit` 模式；Homebrew 仍会执行该软件包自己的安装步骤及附带工具更新。

安装后同时核实 Homebrew 安装记录和应用目录中的版本；带构建号的版本也会核对构建号。命令失败、超时或版本不符均不算成功。更新开始时先记录“尚未核实”，结果再写入同一操作；安装与核实时会阻止正常退出，结束后可再次退出。Thermo 不提供软件更新的自动回退。

「软件管理 → 启动项」可查看 `~/Library/LaunchAgents`、`/Library/LaunchAgents` 和 `/Library/LaunchDaemons` 中的后台服务，并区分用户、共享和系统来源。用户及共享 LaunchAgent 的开关只调整当前用户的启动资格；第三方系统 LaunchDaemon 可在确认后通过 macOS 管理员授权修改系统域启动资格；Apple 与 Thermo 自身的受保护服务保留管理提示。授权结束后会再次核对配置身份、摘要和原状态，执行后读回确认。CLI 使用 `thermo apps startup` 查看，`thermo apps startup disable LABEL --dry-run` 预览；同名项可用完整 plist 路径选择。去掉 `--dry-run` 后交互确认，或加 `--yes` 执行。开关不改写 plist，也不立即停止或启动程序。执行前复核文件、来源和状态，完成后重新读取确认；可在同一页面反向切换，历史记录也提供入口。同一用户域中有多个文件使用相同 Label 时禁止修改。App 注册的其他登录项仍需在「打开系统登录项」或所属应用设置中管理。管理员授权取消、超时或读回不明时会提示未确认；请刷新检查，不会自动回退或重复执行。

## 风扇控制安全机制

- 只有 root helper（`dev.thermo.helper`）写 SMC；转速始终限制在 SMC 报告的 min–max 内。
- 策略由 helper 持有，CLI/App 退出后仍然生效；helper 启动、退出（SIGTERM/SIGINT/SIGHUP）时尝试恢复自动并读回确认，失败会保留反馈。
- 超温保护：有效 CPU/GPU 温度连续 2 次采样（4 秒）达到阈值（Intel 95 °C，Apple Silicon 110 °C）时暂停可能降低散热的策略并尝试自动，全速散热可继续；低于恢复阈值并保持 60 秒后恢复策略。必需温度缺失会立即暂停非全速策略，恢复计时也要求有效读数；完整规则及失败反馈见上文的风扇状态说明。
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

### Claude 清理与隐私设置

App 侧栏的“Claude 清理”提供本地状态重置和隐私/网络工具。重置前逐项展示登录、设置及历史记录的影响；默认不选，保留私有恢复副本，并阻止运行中的 Claude 数据被重置。隐私页支持浏览器定位/WebRTC 设置、mail.com Cookie 清理、用户 launchd 变量清理、DNS 缓存刷新及系统时区操作，每项单独确认。

浏览器设置可恢复；Cookie 备份需手动恢复，launchd 变量清理不可撤销。重置副本仍占磁盘空间。支持范围、原包 REA 证据和限制见[分析记录](docs/kelaude-analysis.md)。本地构建可用 `Thermo --main --page claude-cleanup` 或 `--page claude-cleanup:privacy` 打开。

### 保留开发环境与 NAS 归档

App 的自动勾选和 `thermo clean run safe` 默认保留开发依赖、SDK、模拟器数据、项目编译缓存、AI 模型和工作树。它们仍会显示在扫描结果里；确实不再需要时，可以按具体项目 ID 或分类选择。文件能重新生成，并不代表清理后不会影响下一次开发。

需要长期腾出空间，可以把闲置目录归档到自己的 NAS。使用现有 SSH 配置中的别名，接收端需提供 `tar`、`sha256sum` 和可写目录：

```sh
# 只读预览：目录占用、逻辑大小和实际需要传输的数据分别报告。
thermo space archive ~/Downloads/old-project --to nas:/archive/old-project.tar --dry-run --json

# 默认保留本机原件。归档采用 SSH 流式传输，不需要额外的本机临时空间。
thermo space archive ~/Downloads/old-project --to nas:/archive/old-project.tar

# 完整校验后移除本机副本；非交互调用可加 --yes。
thermo space archive ~/Downloads/old-project --to nas:/archive/old-project.tar --remove-local
```

归档保留稀疏文件的空洞、符号链接和文件元数据。500 GB 的虚拟磁盘如果只实际写入17 GB，不会按500 GB传输。接收端校验归档的 SHA-256，并用原生 `tar` 检查格式，无需远端 Python。传输失败、校验失败、源目录发生变化或被进程占用时，本机原件会保留。已有归档不会被覆盖。

移除原件前会先在归档旁保存 `.manifest.json` 恢复记录。实际空间增量来自同一文件系统的前后测量，包含其他任务同期的写入和释放；目录占用、APFS独占块估算和实际增量不能混用。明确停用的开发环境需要额外指定 `--inactive-development`，不要用它迁走正在开发所需的环境。

恢复时先停止对应应用，从记录中的 `restoreDirectory` 还原：

```sh
ssh nas 'cat /archive/old-project.tar' | tar -xSpf - -C ~/Downloads
```

### 清理结果与本批废纸篓

递归删除中途失败会报告 `outcome: partial` 和 `partialRemoved`，可确认的已删除量仍计入 `bytes`。无法完整比较残留内容时，`bytesIncomplete` 标明估算不完整；系统可用空间变化单独显示，包含并发磁盘活动。

移入废纸篓会记录实际位置和文件身份，并返回 `trashBatchID`。文件仍占用空间，清空后的实际可用空间变化取决于 APFS 共享块、快照及并发活动。

```sh
thermo clean empty-trash BATCH_ID --dry-run --json
thermo clean empty-trash BATCH_ID --yes --json
```

该命令只处理记录中的本批项目；已经恢复、被替换、仍在使用、无法读取或不在当前用户废纸篓中的项目会保留。不会清空整个废纸篓，也不会按原路径追删新文件。

`apps uninstall`、`apps leftovers remove` 和 `space trash` 同样记录批次并返回 `trashBatchID`。放回原处：

```sh
thermo clean restore BATCH_ID --dry-run --json
thermo clean restore BATCH_ID --yes
```

只移动仍是原废纸篓项目（身份未变）、原路径为空、原文件夹仍在同一宗卷的项目，用重命名而非复制；原路径已有新内容时报告 `conflict` 并保留两边。废纸篓位置与状态目录不一致时，向 macOS 查询原路径对应的位置，不从批次文件接受任意目录；显式指定其他 Home 不会扩展到当前用户的原生废纸篓。记录项目的身份检查不等于完整比对目录深层内容；恢复提示不承诺内容未被编辑。带 Git 注册信息的工作树需按下文手动恢复。

App 从历史恢复期间阻止普通退出，成功恢复后使软件清单与关联数据测量失效，返回软件页会重新扫描，避免显示移除前的旧结果。

已在临时可写 APFS 磁盘镜像上验证卷内原生废纸篓的预览、冲突保留与恢复。系统路径别名会统一比较，固定父目录只要求路径搜索权限，不要求能列出每级目录；用户符号链接、路径跳转和跨卷目标仍不接受。其他文件系统和真实外置设备需要单独验收。

工作树会重新检查未提交内容和活动进程，仅对能确认持有者已退出的 Claude agent 锁解锁。移入废纸篓后通过 Git 注销单个注册项，不使用全仓库 prune 或 force；分支保留。恢复所需的 Git 注册副本与 checkout 一起留在废纸篓，位置见批次记录的 `registrationBackup` 和 `registrationOriginal`。恢复时，先确认原路径及注册位置为空，把注册副本移回 `registrationOriginal`，再把 checkout 移回原路径；检查 `git status`。恢复前还应确认同名分支没有被其他工作树使用或改动，不覆盖现有文件或注册项。

### 扫描对比与大目录提示

普通 clean 报告开头显示 swap 文件、模拟器 runtime 磁盘镜像及可清除空间估算。这些数据共用 APFS 容器，不能与目录统计相加，不会据此推断某个进程使用了多少 swap。

扫描快照保存在 `~/Library/Caches/dev.thermo/scan-history/`，最多保留 24 份近期快照和 32 个范围基线。只有同分类、根目录、发现规则、年龄阈值和测量口径的完整结果才参与前后比较；取消、读取失败或有界测量不完整的快照保留供检查，不替换完整基线。

Rust 项目的 target 以及 `~/.cache/*-target`、`*_target` 等具有 Rust 构建特征的目录会显示，即使没有 Cargo.toml；保持默认保留开发依赖和活跃构建保护。Claude scratchpads 改为需要审阅，说明中列出发现的大媒体文件，避免把渲染成果当作一次性缓存直接删除。

旧版本留下的悬空 agent 工作树注册可单独检查与修复：

```sh
thermo clean repair-worktrees --root /path/to/repo --dry-run --json
thermo clean repair-worktrees --root /path/to/repo --yes --json
```

仅处理该仓库 `.claude/worktrees/`、`.codex/worktrees/`、`.worktrees/` 中路径已经不存在的注册。未知锁、活锁、仍被使用或审阅后重新出现的目录保留；注册信息先备份到 Thermo 的私有目录，分支和其他工作树不变。
