# Changelog

## 1.2.1

- 修复部分 M5 机型使用小写 `F0md` 模式键时无法切换最大转速、恢复自动或核对状态的问题；重新发现硬件键，继续检查每次写入结果。
- 菜单浮窗正文固定高度并滚动显示，采样和错误提示不再改变窗口大小；顶部说明预留两行，避免按钮随文字换行上下移动。
- 未知风扇状态不再默认选中「自动」；多风扇快捷按钮一次提交全部风扇，缺少回读键时显示中文说明并保留原始错误详情。

- 修复菜单栏「清洁屏幕」「网络低延迟」「保持唤醒」「电池充电保护」设置弹窗显示全白的问题：工具入口统一由主窗口承载，并在呈现前关闭菜单浮窗。
- 清屏快捷键说明完整换行显示，避免退出方式被截断。

## 1.2.0

- 新增应用和本地文件名搜索：Option+Space 打开，支持中文、拼音、缩写、轻微拼写错误、收藏与别名。文件目录由用户添加，名称索引只保存在本机，不读取文件内容。
- 搜索支持键盘选择、回车打开、Finder 显示、Quick Look 与复制路径；可设置快捷键、排除规则、隐藏文件和使用历史。
- 新增 `thermo search query/status/index/open/settings`，可独立检索本地索引；覆盖不完整或匹配候选达到上限时明确报告。
- AI 检查新增 Claude 本机只读诊断与脱敏报告。

## 1.1.42

- 全部页面视觉重做：统一的字号与间距，每页只有一个主角数字（概览以温度和热量色阶为主）；长说明收进标题旁的 (?)，安全提示仍直接显示。
- 所有可勾选列表统一加「全选」：每组标题上的三态全选，底部栏显示已选数量（Claude 清理、残留文件、磁盘清理分类、空间透视大文件与重复文件、标签整理、MCP 批量检查）。
- 风扇页检测中不再显示假的「0 转/分」；设置页按系统设置的样式分组；菜单面板固定深色。
- 菜单栏图标右键默认弹出原生菜单：直达各页面，保持常亮（30 分钟 / 1 小时 / 2 小时 / 直到关闭）、清洁屏幕、低延迟、充电保护，以及检查更新、关于和退出。
- 新增「连接」页：Wi-Fi 信号、噪声、速率、信道与标准，扫描附近网络；蓝牙已配对设备一键连接/断开，AirPods 显示左耳、右耳和充电盒电量；声音输出切换、音量与静音。网络名称需在系统中允许定位服务。
- 电池详情显示电源适配器功率。

## 1.1.41

- 空间页扫描大幅提速：整个个人目录从几十分钟缩短到约一分钟；各顶层目录轮流扫描，中途停止也不会漏掉大目录；没扫到的目录显示「未测量」，不再当成 0 排到最后。
- AI 检查新增「Worktree」：发现遗留 worktree 过多的项目，文件夹已不存在的记录可一键 `git worktree prune`（不删文件）。磁盘清理现在也能找到仓库外的 worktree（如 `~/.codex/artifacts`），有未保存改动、在用或最近改过的一律保留。
- AI 检查发现过大的数据库预写日志（codegraph、Codex），并提示仍在运行旧版 codegraph 的后台进程；一键升级 codegraph 并正常重启旧进程，不删除 -wal 文件。
- 插件和 Skill 可以检查更新、一键更新：Claude Code 插件按本地市场目录比较版本，Skill 用 `thermo agents updates --check` 到 GitHub 核对；更新和卸载都调用各工具自己的命令。长期没用或装了从没用过的 Skill、插件会提示；Codex 插件也列出并可卸载。
- 新命令：`thermo agents updates [--check]`、`thermo agents update [名称]`。

- 应用菜单与 ⌘⇧P 可直接打开菜单小面板，即使左右键都设为主控制台；正文按屏幕高度滚动，底部操作说明、设置与快捷工具固定显示。进入控制台时显式关闭小面板，隐藏面板不再保留采样；当前读数与历史曲线分开，等待新样本时显示未知。

- 风扇数量读取失败或非法时保留未知状态并重试，只有确认零风扇才显示无风扇；发现缓存升级为 v3 并校验记录完整性，未知结果不写入缓存。风扇控制拒绝使用未知发现结果。CLI 和流式 CSV 保留风扇可用性，恢复后保持列布局一致。

- 风扇状态区分尚未采样与实际空结果，后台只读温度时不会在面板、概览或风扇页误报“无风扇”。
- 内存页先显示当前读数，再补历史曲线；重开时等待旧读取结束并丢弃旧结果，增长分析共用同一份已排序时间线。
- CPU 页重开会在旧读取结束后立即刷新，关闭时取消尚未开始的读取及进程遍历；内存页关闭后不再接受延迟刷新，当前可见页面的采样使用交互优先级。

- 新增普通保持唤醒：屏幕、任务或组合模式，支持限时和手动结束；低电量暂停，接电后恢复。面板关闭后继续，退出 Thermo 后结束。
- 菜单栏支持独立主次指标、单项或双项、图标和数值组合、横向或双行显示，以及左右键分别打开面板或主窗口；新增 CPU 使用率、内存和上传下载速度。保留旧设置与 CLI 用法，缺失或过期读数显示未知。
- 项目构建产物扫描覆盖主目录下的普通一级目录，排除系统目录、媒体库、同步盘和其他挂载卷；补充 Swift 项目的 `dist` / `build` 及影片项目的 `out`。
- 按内容识别构建缓存时校验 `CACHEDIR.TAG` 的标准签名，拒绝同名目录、管道和软链接；执行不可恢复清理前再次核对扫描时的缓存依据，依据改变时要求重新扫描。

## 1.1.38

- 磁盘空间提前提醒：剩 30 GB、15 GB 时各提醒一次（之后每 12 小时提醒一次），剩 5 GB 时每小时提醒；按最近 15 分钟的写入速度，3 小时内会写满时也会提醒。swap 占用较多时，提醒里会说明它占了多少硬盘。可在设置里和其他提醒一起关闭。
- 清理项目构建产物时，`node_modules`、`.build`、`target` 等可重新构建的目录改为直接删除，不再移进废纸篓。以前移进废纸篓后空间并没有释放。`dist`、`build`、`out`、`coverage` 可能存有需要保留的文件，仍然移进废纸篓，可以恢复。
- `thermo clean run` 支持把多个 ID 写在同一个带引号的参数里（按空格拆开）；有 ID 没匹配上时，报错会列出是哪几个。
- AI 诊断：按外层工具拆分返回用量，区分调用累计耗时和观察占用时间，单独统计 Skill 指令正文的加载量，可显式分析单个会话的日志；MCP 错误按工具自报的错误码细分，并检查失效的本地 schema 引用和 Skill 目录引用。
- 辅助程序：升级时保留用密码安装的服务注册，等旧进程退出后再加载，安装中途失败不会再误报成功；风扇恢复自动模式时会等读回确认。
- 独立窗口关闭统一经过完整的退出保护；废纸篓恢复能识别原项目已经放回；标签加入已有分组却落进新组时会报告失败。

## 1.1.28

- 新增清洁屏幕：限时黑色遮罩、输入拦截、退出与恢复保护；可选全局快捷键默认关闭，支持录制、冲突检查和移除。
- 进程说明增加当前父子关系、工作目录附近的 Git 信息、TCP 监听和电源请求；结果注明读取范围和缺失信息，不把当前祖先当成原始启动者。
- AI 会话默认全部保留。清理旧会话需要明确选择保留期限，执行前再检查运行状态、保护范围及扫描后的变化。
- 开发缓存原生命令绑定扫描时的目录、程序和执行范围；确认后工具或白名单变化会停止工具操作。修正工具删除整个目录后的空间计量和部分失败记录。
- 风扇读数与控制状态不可用时显示未知，区分请求策略与硬件复查；缺少有效转速范围时禁用最高转速设置。
- 新增限时 AWDL 网络控制入口和 `thermo awdl` 命令，需更新辅助程序。使用期间 AirDrop 等点对点功能可能不可用；状态、停止和恢复结果单独显示，不承诺延迟收益。
- MCP 配置可明确勾选后按顺序批量检查，支持停止和总时限；仅启动所选配置服务并读取定义，不调用业务工具，也不将结果当作宿主实际加载配置的证明。

## 1.1.27

- 标签智能分组不再重复建组：同一网站在同一窗口已有 Thermo 建的分组时，新标签加入该分组（单个新标签也会加入），不再每分钟新建一个同名分组。需要 chrome-use 扩展支持（随下一版 chrome-use 发布）；扩展还不支持时，自动分组会跳过这些标签，不再重复建组，界面会提示更新。
- 只加入 Thermo 自己建的分组：通过分组记录确认，不按标题匹配。chrome-use 的 agent 分组，以及你自己建的分组，即使同名也不会被改动。已在分组里的标签保持原样。
- `thermo tabs organize --dry-run` 会标出哪些分组是「加入已有分组」，确认提示也会分别列出新建和加入的数量。

## 1.1.26

- `thermo pulse` 每一行都把同一程序在同一文件夹的所有进程算进来，不再只合计其中较大的几个；同一程序在其他文件夹还有副本时，会标出「另有 N 个进程在其他 M 个文件夹」。JSON 新增 `processCount`、`elsewhere`、每个进程的 `ppid`/`owner`/`project`，以及 `sampled`、`units`（各数值的单位和内存口径）和 `selection`（列出哪些程序、每行统计范围）。同一行的进程由不同 agent 启动时，不再只写第一个，而是全部列出（`owners`）。
- 新增 `thermo pulse inspect NAME|PID`：一个程序在所有文件夹的全部副本，逐个进程列出内存占用（footprint）和 RSS、CPU、运行时长、父进程和启动者，并标出启动者已退出的进程。只能作为判断是否遗留的线索，不能直接证明泄漏。
- `thermo pulse history` 记录每行的进程数和内存口径（`peakProcesses`、`memoryMetric`），JSON 附带单位说明。
- `thermo agents` 的进程列表注明内存是驻留内存（RSS），JSON 增加 `memoryMetric`。
- 内存页把口径说明移到程序列表上方：内存占用即活动监视器的「内存」列，含压缩内存（可能部分已换出），各程序相加不等于已用内存，也不等于 swap。
- 不在 Thermo.app 里的 `thermo` 副本（例如复制到 `~/.local/bin` 的）比已安装的 App 旧时，会提示版本差异，并给出改成指向 App 自带命令的方法；不会自动改动该文件。

## 1.1.25

- 菜单栏面板重新设计：CPU、GPU、内存、可用空间、网络、风扇改成卡片，有最近两分钟的曲线和温度标记；电池显示放电功率和剩余时间；「占用最多的程序」标出所在项目和启动它的 agent；顶部一句话说明现在是否过热或超负荷、主要原因是什么。
- 清理开发缓存时优先用工具自己的命令：npm、Yarn 1、pip、uv、Go 构建缓存分别执行各自的清理命令（如 `npm cache clean --force`）。找不到工具、被白名单保护或选择移到废纸篓时，按原方式处理；命令失败时保留文件夹，不在出错的工具背后删除。确认前会列出将要执行的命令。
- 支持用 Homebrew 安装：`brew install --cask leeguooooo/tap/thermo`，App 和 `thermo` 命令行一起装。
- 新增启动项管理与 Homebrew 应用更新，卸载前复核应用文件。

## 1.1.24

- 「合盖不休眠」新增「过热时自动关闭」选项（默认开启，可在菜单栏取消勾选；命令行用 `thermo awake on --no-heat-guard`）。关闭后只在使用电池且电量降到 20% 时自动关闭；macOS 仍会在温度过高时自动降频，到危险温度会强制关机，风扇超温保护也保持开启。辅助程序会自动更新。

## 1.1.23

- 修正「合盖不休眠」在部分 Apple Silicon Mac（如 M3）上按 Intel 标准在 85 °C 就自动关闭的问题，改为按实际 CPU 判断，Apple Silicon 为 100 °C。

## 1.1.22

- 菜单栏新增「合盖不休眠」开关（笔记本，经 Thermo 辅助程序；也可用 `thermo awake on|off|status`）。以下情况会自动关闭并发通知：温度比风扇安全上限低 10 °C（Apple Silicon 100 °C，Intel 85 °C）时；使用电池且电量降到 20% 时；连续读不到温度时。关闭、辅助程序重启或更新时，都会恢复你原来的睡眠设置，不会一直保持开启。首次使用需要更新辅助程序。
- 概览新增「最近 15 分钟」时间线：温度和每核负载上下对齐，标出哪个程序开始或停止大量占用 CPU（带项目和 agent），以及 Thermo 做过的操作。
- 传感器页、风扇页改用和概览、操作记录一致的面板样式；风扇的转速范围和模式直接显示在名称下面。
- 卸载由管理员账户安装的应用时，会先说明 Thermo 无法移动它、请在访达中拖到废纸篓，不再中途失败。（1.1.21 说「可以放回 root 拥有的应用」并不准确：macOS 不允许 Thermo 移动这类应用，所以它们不会进入可恢复的批次。）

## 1.1.21

- 概览改为「热链路」：顶部一句话说明为什么热、为什么慢，同一项目里由同一个 agent 启动的程序合并点名；中间按负载 → 温度 → 风扇 → 系统热压力排列，标出出问题的一环，风扇的自动/最大就在风扇这一环上；其他资源收成一行。
- 新增「操作记录」页和 `thermo history`：清理、卸载、agent 修复、Claude 重置、隐私设置、标签整理、归档和退出程序都记在同一个日志里，每条写明在哪里撤销；大小未测量时不写成 0。
- 卸载应用、移除残留和空间透视的移到废纸篓都会记成批次，可在操作记录页或用 `thermo clean restore BATCH` 放回原处；原位置已有新数据、废纸篓里的项目被改动或换过时会跳过，不会覆盖。
- 新增持久清理白名单（`thermo clean whitelist`，或在智能扫描里选「始终保留」）：所有清理、卸载和移到废纸篓都会跳过白名单里的路径；白名单文件不可信或读不出时拒绝清理。

## 1.1.20

- 重新设计“Claude 清理”页：摘要显示本地数据、可重置和锁定数量，锁定原因及解除方法只说明一次；按 Claude Code、桌面端、Claude-3p 分组，每行一句影响，展开查看完整说明、路径和锁定原因。
- 底部操作栏显示已选项目和大小，并说明数据移到私有恢复目录、不会释放空间；确认窗口逐项列出完整影响和路径，仍需输入 RESET。
- 恢复记录显示项目数、大小以及部分或全部已恢复状态，全部恢复后不能再次恢复；无法测量的大小显示为未知，总量显示为下限。
- 隐私与网络页改为逐行操作，标注需先退出浏览器、需管理员授权、无法撤销、会发送公网 IP 等前提，执行前仍显示完整说明。

## 1.1.19

- 新增独立“Claude 清理”页：逐项重置 Claude Code 与桌面端本地状态，执行前确认，保留私有恢复副本，保护运行中的会话及新生成的数据。
- 新增隐私与网络工具：浏览器定位/WebRTC 设置及恢复、mail.com Cookie 定向清理、Claude 用户 launchd 变量清理、DNS 缓存刷新和时区查询/切换。浏览器修改要求完全退出，Cookie 备份附来源清单，系统操作单独授权。

## 1.1.18

- 新增 CPU、GPU 占用页面：整机使用率、最长 15 分钟的实时曲线、按程序汇总的占用列表；可搜索程序、项目或 PID，展开查看各进程。
- 程序 CPU 通过两次采样计算，100% 对应一个逻辑核心；GPU 时间占比来自驱动可读取的客户端，缺失计数器明确显示未知，新进程和计数器重置重新建立基线。
- 页面打开时每 2 秒采样，离开后停止。新增只读命令 `thermo activity --json`，与界面共用采样器。

## 1.1.17

- 标签整理拆成“整理 Chrome 标签”“暂存并关闭”“已暂存”三个明确入口；默认展示 Chrome 分组预览，自动整理与自定义规则收进进阶设置。
- 暂存操作说明保存网址后关闭页面，确认前列出实际操作范围；当前、固定、音频等受保护页面明确显示保留，切换窗口会清除选择。
- 已暂存页面提供重新打开入口与空状态引导；窗口选择显示当前页面标题，本地分类说明与 Chrome 原生分组的区别。

## 1.1.16

- 清理扫描在 JSON 模式下也持续显示 stderr 进度，默认采用 60 秒协作式预算；支持 `--timeout`，大型项目和工作树有界测量并明确标记估算、下限，`--exact` 可完整测量。
- 工作树清理重新检查内容、进程和锁持有者，只通过 Git 处理选中注册项；文件与恢复所需注册副本保留在废纸篓，分支保留。新增 `clean repair-worktrees`，审阅后可备份并修复指定仓库已有的悬空 agent 注册。
- 递归删除中途失败时计入可确认的已删除估算，报告部分完成和剩余错误，无法完整计量时明确标记未知；日志和 JSON 同步记录结果。
- 废纸篓清理返回批次编号，新增 `clean empty-trash BATCH --dry-run` 和 `--yes`，只处理本批记录的项目；已恢复、替换、身份变化或仍被使用的内容保留。
- 清理报告增加 swap、模拟器 runtime 镜像和可清除空间信息，区分目录占用与共享容器数据；保存扫描快照，完整同范围、同口径的结果显示前后大小变化。
- 识别没有 Cargo.toml 的 Rust 缓存 target，保留开发依赖与活跃构建保护；Claude scratchpads 改为审阅，并提示大媒体文件，避免误删渲染成果。

## 1.1.15

- 内存页按程序汇总同名进程，展开后查看各项目与完整进程列表；支持按程序、项目或 PID 搜索，数值和操作按钮对齐，窄窗口使用分行布局。
- 分开显示内存占用与驻留内存，修正两种口径混用和读取失败时显示为零的问题；不再根据两者差值断言程序已被压缩或换出。
- 新增程序占用曲线和当前 swap 读写速率；持续增长提示校验进程身份，不把重启、成员变化或仅仅运行时间长当作泄漏证据。
- 汇总展示保留各项目的结束范围及受保护进程规则，不会一次结束所有同名程序。
- 新增只读命令 `thermo memory --json`，与内存页共用采样和归组结果。
- 标签整理预览显示标签总数。

## 1.1.14

- 支持自动整理 Chrome 原生标签组：按网站或自定义域名规则生成预览，确认后执行，可撤销；已有标签组和受保护页面保持原样，不跨窗口或账号移动。
- 增加可选的持续自动整理：Thermo 运行期间每分钟处理新出现的符合条件标签，默认关闭，不会关闭任何页面。
- 标签整理支持同时读取多个 Chrome Profile，按标签所属账号重查保护状态，不切换其他 agent 的浏览器连接。

- 增加标签组管理：按网站归类、自定义分组、保存后批量关闭、按组恢复；App 与 thermo-use 共用记录。
- 批量关闭保留当前、固定、音频、隐私及 agent 标签；保存记录校验、逐页重查、操作日志和跨进程互斥防止误关与重复恢复。
- 支持 `thermo tabs`，默认操作前方窗口，可指定分组、标签或窗口，恢复时可明确选择目标窗口。
- 默认清理保留开发依赖、SDK、模拟器数据、编译缓存、AI 模型和工作树，避免清理后立刻重建或下载。具体项目仍可手动选择。
- 新增 `thermo space archive PATH --to nas:/archive/name.tar`：通过 SSH 流式归档，保留稀疏文件、链接和元数据；接收端落盘、校验 SHA-256 与归档格式后保存恢复记录。默认保留本机原件，`--remove-local` 仅在源目录未变且未被占用时移除原件。
- 修正 APFS 签名副本的说明，区分含共享块的目录占用、独占块估算和清理后的实际可用空间变化。

## 1.1.13

- Where the space is accounts for the whole disk: every folder in your home, Library and the system data volume falls under a heading (apps, app data, projects, tool and agent folders, Apple's downloaded models and voices by name, system-wide data), macOS's own volumes are shown as what cannot be removed, swap and the sleep image come from the VM volume, and each heading says what to do about it. What cannot be attributed (APFS metadata, local snapshots) is one named line, and hard links or clones counted twice are said instead of hidden.
- A nearly full disk is named as the reason the Mac is slow (swap cannot grow, every write waits) instead of the busiest program; a warning appears below 5 GB.
- Leftover code-sign clones of apps (Chrome left one per relaunch): free while they share blocks with the app, a full copy each once it updates; the one a running app uses stays.
- The full cleanup scan takes about 35 s instead of minutes: APFS is asked for a file's reclaimable size only when the file may be a clone. Removing a chosen item no longer scans everything first, and 1,600 agent sessions go to the Trash in seconds instead of minutes.
- Cleanup categories show what is held back by a running app next to what can go now. The `claude` command line and Claude.app's browser helper no longer count as the Claude app running, which kept its caches from ever being cleaned.
- Memory gets its own section: where the memory is (apps, wired, compressed, cached files, free), swap on the disk, memory and swap over the last hour, six or 24, and every program by memory with its helpers and pages folded in, each with Quit, Restart or (for a browser) its pages.
- Worth a restart: programs that keep growing and do not come down, and big apps that have run for a day or more (Xcode, 26 h, 2.4 GB). Thermo records each program's memory every five minutes to tell a leak from a program that is simply big.
- When the disk is nearly full the Memory page says so first: swap cannot grow, which is what makes macOS say it has run out of application memory and ask you to force quit apps.
- Space Lens (Disk Cleanup): your home folder measured once, then any folder opens at once, biggest first, with a block chart beside the list; click a block or a row to look inside. Tick files or folders from any tab into one basket; they go to the Trash after a confirmation that lists every path. macOS and tool folders, keys, iCloud, mail, photo library insides and git metadata cannot be picked, and anything a program has open is skipped.
- Large files: everything of 100 MB or more, with when it was last opened, filtered to files not opened for 3 months or a year.
- Duplicates: identical files of 1 MB or more in Desktop, Documents, Downloads, Movies, Music and Pictures, compared byte for byte; keep the oldest of each in one click.
- `thermo space [PATH]`, `thermo space large`, `thermo space dupes` and `thermo space trash` do the same in the terminal.

## 1.1.12

- Uninstalling an app or removing leftovers updates the list in place instead of measuring every app (or searching for leftovers) again.

## 1.1.11

- AI Agent Diagnostics finds programs an agent started that keep crashing (each crash leaves a report and can show the "quit unexpectedly" dialog), with the crash reason and the newest report; it names the MCP server or hook that runs the program when only one does, otherwise the ones it could be.

## 1.1.10

- Uninstall apps (Disk Cleanup → Uninstall apps, or `thermo apps`): the app and the files it keeps in your home folder go to the Trash after you see every path; running, system and protected apps (password managers, VPNs, input methods, security software) are refused. Data left by apps you already deleted is found too (`thermo apps leftovers`).

- Cleanup checks each path again just before removing it: a path swapped for another file since the scan, or one a running program holds open (files or working directory), is skipped and named. Ages count when a file was moved or unpacked, not only its modification date.
- New cleanup items: Chrome, Edge, Brave, Arc and Chromium GPU and script caches in every profile; caches of Electron apps that are not running; editors' replaced extensions (VS Code, Cursor, Windsurf); Corepack, Electron, TypeScript, Carthage and Android caches; unfinished downloads and `.ipsw` firmware in Downloads.
- Homebrew's old versions (`brew cleanup`) and Go's module cache (`go clean -modcache`) are cleaned by the tools themselves, sized by Homebrew's own dry run.
- `pnpm store prune` removes packages no project uses; the result reports the space it actually freed. Chrome, Edge and Brave's previous version, left inside the app after an update until a restart, can be moved to the Trash while the browser is closed; the version in use and the app's signature stay intact.
- Uninstalling a browser, chat or mail app keeps its profiles, chat history and mail unless asked for (`thermo apps uninstall NAME --with-data`); the confirmation lists what stays.
- iOS device support keeps the two most recently used versions. A folder another rule covers (such as an app's logs inside ~/Library/Logs) is counted once.

## 1.1.9

- Disk scans show results as folders finish, support stopping and time budgets, and keep incomplete measurements clearly labeled. Scanning uses bounded concurrency and less memory.
- Space Overview lists projects and source folders separately, with shortcuts to scan build output, Xcode files, developer caches and temporary leftovers.
- Project cleanup recognizes build directories such as `target`, `.build`, `dist` and `node_modules`, preserves Git-tracked files and checks running agents, build tools and executables before removal.
- Cleanup dry-run never deletes files or runs commands, even with `--yes`. Confirmation distinguishes Trash from permanent tool-managed removal; simulator cleanup uses reviewed device IDs and checks live state.
- Cleanup reports measured disk space before and after, separately from estimated file sizes. Path protection checks symbolic-link ancestors, and cached plans keep their original scope and scan dates.
- Browser pages support selecting several tabs and reviewing duplicate or growing pages, protect active or unknown-current tabs, and recheck memory after closing. Slowdown actions now recheck their results.
- Native cleanup pages show progress, a Stop button and an explicit partial-results notice. Space Overview can reuse CLI measurements in the selected language without rescanning.

## 1.1.8

- Browser pages read Chrome through chrome-use (1.5.186+): the tab list without attaching to pages, memory per page only when you ask (`thermo pulse chrome --measure`, or `--watch 60` to see which pages grow), pages not measured are counted, and stale chrome-use records are no longer mistaken for hidden pages. It tells you when chrome-use's Chrome extension is out of date or its update is waiting.
- Sensors has a battery card: charge, health, cycles, power source, temperature, voltage and current.
- Keyboard: ⌘1–⌘6 switch pages, ⌘F searches sensors, diagnostics and disk categories, ⌘, opens Settings; the Edit menu works in text fields.
- Disk: "Where your disk space is" can be stopped, keeps earlier results while measuring, and says which folders it could not read. Cleanup confirmation lists the paths it will remove.
- Fans: settings apply one at a time with visible progress; invalid curve points are refused; a helper connection failure is shown as such.
- Temperatures, charts and alerts follow the Fahrenheit setting; macOS thermal pressure is shown separately from sensor temperatures.
- Many reliability fixes in diagnostics, browser checks, cleanup and the command line (details below).

## 1.1.8 — all changes

- Process diagnosis marks failed reads as incomplete; unknown launchd ownership no longer creates orphan classifications or stop-process fixes. Agent session names are excluded from end-process actions.

- Browser and diagnostic subprocess calls have bounded time, cancellation checks and capped, continuously drained output. Cancelling diagnosis skips the second sample and the tab-list fallback.

- Invalid battery registry values remain unknown instead of appearing as negative health/cycles or non-finite measurements. Charge is bounded to 0–100%; nested power state and unsigned discharge-current compatibility are retained.

- CPU and memory gauges scroll to the live resource details instead of reopening the same page.
- Sensors includes a read-only battery card for charge, health, cycles, power source, temperature, voltage and current; the Overview battery chip now leads to those details.

- Custom build output paths are checked before compilation; repository ancestors, source directories and system/installed-app locations are refused. Packaging replaces only its known products and preserves other files in the output directory.

- Packaging validates the app, standalone and embedded CLI/helper signatures, requested architecture slices and minimum OS metadata; Sparkle's requested slices are checked too.

- Watch input buffers coalesced keys and fragmented escape sequences. Direction keys arriving in pieces no longer look like a bare Escape; both CSI and application-cursor arrows are accepted.

- Watch page changes redraw the current snapshot without consuming samples or resetting the interval; tiny terminals no longer produce negative row counts. Terminal restoration occurs once on exit.

- CLI rejects flag assignments such as `--yes=false` and non-finite sampling intervals. Terminal polling clamps large waits and checks signals every 100 ms.
- `thermo settings` exposes slowdown alerts and unnamed sensor readings for agent/script access.

- Native View menu lists the main pages and their keyboard shortcuts. Language changes relabel the native menus without adding duplicates; page menu actions wait until a confirmation sheet is closed.

- Disk Cleanup cache rejects cancelled reports, duplicate IDs, negative sizes and overflowing totals. Invalid saves do not replace the last valid cache.
- Disk scans retain their starting language; changing the UI language preserves results and selections with a rescan notice instead of automatically repeating a long scan.

- Diagnostics reports retain their generation language; a language change bypasses the age cache. Reports produced in the previous language are discarded and refreshed after any active repair finishes.

- Alert settings show notification authorization separately from the alert switches, including missing permission, denied access and disabled banners. Enabling slowdown alerts requests permission, and returning from System Settings refreshes the status.

- The menu-bar hottest metric and hot alerts use the same full curated temperature scope as the open window. Default background CPU sampling remains essential-only.
- Sensors can include unnamed readings for SMC-key troubleshooting; the wider scope is released when leaving the page.

- Overview memory, process memory and swap use a shared MiB/GiB formatter in the app and CLI; disk cleanup retains decimal MB/GB. Overview details wrap instead of shrinking into a single line.

- Diagnostics retains the latest 20 operation results during the app session, including failed steps and backup locations, even after an item disappears from the inventory.
- Batch repair results list each action and its output in a scrollable sheet with a reachable Done button. A separate execution flag keeps scans and repairs mutually exclusive while views change.
- Failed diagnostic steps are written to the action log with redacted error output.

- Disk-space caches retain the original measurement time and language. Cancelled, future-dated, invalid and mismatched-language caches are rejected.
- Disk-space measurement records unreadable locations and shows a permission notice rather than silently treating them as empty.

- Disk-space measurement has a Stop action, stops when its page or window closes, keeps completed results after cancellation and does not cache partial measurements. Its cancellation token is independent of Disk Cleanup.
- A failed helper connection is labeled as a connection failure rather than claiming the helper has stopped.

- Fan policy changes run one operation at a time, show an applying state, and read back active policies even when a write fails. Pending settings for multiple fans apply in order.
- A helper version response alone no longer makes a stale policy appear active; unavailable policies have no active quick-switch highlight. Preset fan curves explicitly label Celsius.

- Offscreen screenshots do not change saved window placement; windows saved on disconnected displays reopen on screen.

- Disk-space refresh keeps previous locations visible as new readings arrive; disclosure buttons work with the keyboard.
- Label macOS thermal pressure separately from sensor temperature. Retained swap alone no longer explains a slowdown when current load and memory pressure are normal; restart advice reports current memory instead of promising a specific saving.

- Quit/end and restart recheck executable path, process start time and user identity against the captured reading; exited or replaced processes are skipped with an explanation.
- Hot notifications and alert thresholds follow the Fahrenheit setting.

- Browser page closes update memory totals, biggest-page rankings and duplicate counts; new checks cannot race a pending close, and rechecks show progress while keeping the previous result.
- App restart reports a refused quit or failed reopen; saved browser tabs are only reopened after the app launches successfully.
- Release the Mach host port after each memory reading.

- Keep unselected sessions and failed paths visible after partial cleanup; remeasure remaining data and invalidate the old scan cache.
- Completing a disk scan preserves choices made while results were arriving; stopped scans and unreadable locations are labeled as incomplete.
- Helper setup times out without restarting installation or applying queued settings; repeated setup and status checks are coalesced.

- Reject invalid and duplicate fan-curve points, preserve decimal values when editing a saved curve, and validate policies in the privileged helper.
- Disk Cleanup confirmation lists the paths that will be removed. Pending fan settings are labeled as waiting for the helper.
- Keep agent scans and fixes mutually exclusive; category batch fixes now show their commands for confirmation. Search reveals healthy matches too.

- Add the native Edit menu so Select All, Copy, Paste and Undo work in text fields.
- Search sensors by name, group or SMC key with ⌘F; switch main pages with ⌘1–⌘6 and open Settings with ⌘,.
- Temperature charts follow the Fahrenheit setting and include readings above 105°C. Empty charts explain what they are waiting for.
- Show CPU load as load per core rather than a CPU usage percentage.
- Browser checks show a stopped state and keep the previous result during a new check. Leaving the page or closing the window cancels checks for every browser; late progress from cancelled checks is ignored.
- Main-window errors are visible, with retry after sensor initialization fails. Disk Cleanup reports changed scan scopes and errors, searches paths, and provides keyboard-accessible selection and detail buttons.
- Align disk-space details with the other pages; label Settings controls for accessibility and honor Reduce Motion for page transitions and the scan halo.

## 1.1.7

- One console window for everything (the "Open Console" button in the menu bar panel, or click the Dock icon): Overview with gauges for temperature, CPU load, memory and free disk space, why the Mac is slow and the temperature trend; Sensors as a card per group; Fans; Browser pages; Disk Cleanup and AI Agent Diagnostics; Settings — all in one sidebar.
- The menu bar panel is now a glance: the live numbers, why the Mac is slow, a one-click Auto / Max fan switch, an "Open Console" button and shortcuts to its pages.
- Disk Cleanup scans everything by default and finds build output it missed: `dist`, `build`, `out`, `coverage` and similar folders in web and Python projects (skipped when git tracks them; offered for review, since they can hold renders or release builds).

## 1.1.6

- "Why is my Mac slow" says why in plain words: how much memory has been moved to the disk and that programs are waiting on it, and which program is behind it.
- Big apps are broken down: Chrome and other multi-process apps show their GPU process and heaviest pages, with how long each has run.
- Long-running apps that hold gigabytes get a concrete suggestion ("Chrome has run 31 hours and opened about 2,000 pages; restarting frees about 19 GB") and a Restart button. Thermo checks whether the app reopens its own windows; when Chrome does not, Thermo saves the tabs first and reopens them after the restart.
- Chrome page diagnosis (Overview → "查看页面", or `thermo pulse chrome`): which pages keep growing (memory, DOM nodes, or event listeners piling up), the biggest pages, duplicate tabs, and busy background workers, with a button to close a page. It lists tabs without touching them; measuring memory is a separate click, because Chrome briefly shows its "being debugged" bar while it measures. Needs chrome-use for the memory figures.
- Slowdown history: Thermo notes every minute (every five on battery) what was slowing the Mac, kept for 24 hours — a chart on the Overview and `thermo pulse history`. Cost: about 0.02% of one core.
- Slowdown alerts (Settings → "Warn me before my Mac slows down", on by default): swap growing past 8 GB, memory under pressure, one program using over 1.5 cores for 10 minutes, or thermal throttling — with who is behind it and what to do. Nothing is ever quit automatically.

## 1.1.5

- Your fan setting survives updates and restarts: the helper remembers it and puts it back when it starts (over-temperature protection still applies). Before, an update or reboot quietly returned the fans to automatic.
## 1.1.4

- Disk Cleanup has the same look as AI Agent Diagnostics: a Smart Scan home that says how much can be freed with one button for the safe part, a card per category, and pages where each item opens in place to show its sessions or files. It opens with the last scan when that is recent, instead of scanning from scratch.
- AI Agent Diagnostics has a new look: one verdict ("14 problems found, 9 can be fixed with one click"), a big Fix button that runs the safe fixes with progress and a result, colorful category cards, and plain-language problem cards with the fix right next to each; technical details are one click away.
- Disk cleanup finds more of what fills a Mac: unused Xcode simulator runtimes and simulator data (removed through Xcode's own tool), OrbStack's disk image, and chat apps' storage (Lark, WeChat, WhatsApp, Telegram, Slack…, shown with where to clear it inside the app — Thermo never deletes chat history).
- "Where the space is": the disk's used space by place — apps, app data, caches, Xcode, temporary files, Homebrew, simulator runtimes and swap — with the biggest folders in each (`thermo clean overview`).
- Sizes are what deleting would actually free, so copies that share space on disk (like Chrome's code-signing clones) no longer look huge.
- Disk cleanup moved into its own window (the popover's Disk tab now just sums up and opens it): categories on the left, build output grouped by project with when each was last used, sortable and searchable, and a detail pane with every path or session and why it is safe to remove. `Thermo --disk` opens it directly.
- Settings → AI agents (thermo-use): one click puts the `thermo` command where AI agents find it and adds the thermo-use skill to Claude Code or Codex; it shows what to ask your agent. thermo-use is part of the *-use family.
- Everything the app does is now also a command for agents and scripts: `thermo pulse quit NAME` (the Quit button on the "why is it slow" card) and `thermo settings` (menu bar text, interval, alerts, units, language, Dock icon; a running Thermo applies changes at once).
- Projects are found through the folders your AI agents and editors worked in, and "last used" comes from those sessions and git, not just file dates — so build output of projects you stopped working on is told apart from ones you use every day.
## 1.1.3

- Thermo itself stays out of the way: the "why is my Mac slow" card checks programs only while the panel is open, and each check is far cheaper (about 0.6% of one core with the panel open).
- Busy command-line programs say what they are and whose they are: "vitest ×4 · ~/code/shop · started by Claude Code" instead of a row of "node". Thermo no longer lists itself.
- Turning on fan control takes one click and your Mac password once — no trip to System Settings. After that the helper updates itself along with Thermo (it only accepts a newer helper signed by Thermo's developer), so updates never ask again.
- A fan setting you choose before the helper is ready (say, max) is applied as soon as it is.
- Turning on fan control no longer hangs on "Setting up…" when an earlier System Settings (Login Items) registration is stuck; it goes straight to the password prompt.
- After the password prompt the Fans tab picks up the new helper right away (it kept talking to the old one until Thermo was restarted).

## 1.1.2

- `thermo pulse` (also `thermo status`): why this Mac is slow, in one command — the verdict, which program is behind it, load, memory pressure and swap, thermal state, temperatures and fans; `--json` for scripts and AI agents. AI agents get it through the [thermo-use](https://github.com/leeguooooo/thermo-use) skill.
- Memory per program now counts what Activity Monitor counts (compressed and swapped memory included), so the biggest memory users are named correctly.

## 1.1.1

- Setting a fan to max now keeps it at max when the Mac gets hot. Before, over-temperature protection handed it back to automatic control, so the fan slowed down exactly when you needed it most. Other fan settings are still paused while the Mac is too hot, as before.

## 1.1.0

- **Why is my Mac slow?** The Overview now opens with a one-line answer: overloaded, too hot and throttling, or short on memory, and which program is behind it. The busiest programs are listed with a Quit button (apps quit like ⌘Q; system processes and AI agent sessions are never offered).
- Thermo has a Dock icon (Settings → Show in Dock), and clicking it opens the panel.
- When the menu bar icon is hidden behind the notch, Thermo opens its panel on launch and explains how to make room.
- New **Agents** tab and `thermo agents` command: diagnoses the AI coding agents on this Mac (Claude Code, Codex, Cursor, Gemini). Finds hooks and MCP servers whose programs are missing, plaintext credentials in MCP configs, plugins that are enabled but not installed, broken skill symlinks, launch agents stuck in a restart loop or pointing at deleted programs, and agent processes that leaked or still run a deleted binary. Read-only; secrets are redacted.
- AI agent diagnostics can now fix and uninstall: remove broken skill links, MCP servers, hooks and launch agents, stop launchd restart loops, end leftover processes, disable or uninstall plugins. Every action shows the exact steps first, backs up config files and moves files to the Trash.
- New diagnostics window (sidebar of checks, item list, details with suggestions and actions); the popover tab is now a summary.
- Disk cleanup (`thermo clean`, Disk tab). It recognises what AI tools leave on disk:
  - Claude Code, Codex and Gemini CLI sessions, grouped by project;
  - Cline, Roo and Kilo tasks;
  - editor chat data for projects that have been deleted;
  - agent worktrees;
  - old CLI and plugin versions and agent scratch folders;
  - Ollama, Hugging Face and LM Studio models.

  It also covers developer caches, Xcode, project build output, browsers and logs. Sessions that are still running, apps that are open and anything with unsaved work are skipped. Caches are deleted; your data goes to the Trash.
- Thermo speaks Chinese: Settings → Language (System / English / 简体中文). The `thermo` command stays English unless `THERMO_LANG=zh`.

## 1.0.4

- Over-temperature protection no longer throws away your fan settings: fans go back to automatic control while the Mac is too hot, and your fixed speed or curve comes back once it has cooled down.
- Apple Silicon: the protection triggers at 110 °C instead of 95 °C. These chips normally run their cores at 100–115 °C under load, so the old limit kept switching curves off for no reason.
- A single brief temperature spike no longer triggers the protection; it has to last a few seconds.

## 1.0.3

- Apple Silicon: switching a fan back to Auto works again (it left the fan at its last manual speed); if returning to Auto ever fails, every fan is reset to system control.
- Apple Silicon: setting a fixed speed or curve no longer reports a timeout while the fan control is being unlocked.

## 1.0.2

- Thermo now lives at app.leeguoo.com/thermo — downloads and updates come from there.
- After an update, the fan helper restarts itself on the new version (fans briefly return to automatic control).
- Product screenshots render the panel tabs correctly.

## 1.0.1

- Apple Silicon: fans under system control are no longer shown as "manual", and returning a fan to Auto restores the system's own fan mode.
- Battery temperature and health on recent macOS versions.
- Lower background CPU use on Apple Silicon.
- Sensors that share a name are now listed separately.

## 1.0.0

- Menu bar app showing CPU/GPU temperature, fan speed or system power, with a 10-minute history chart.
- Every SMC temperature sensor with readable names and groups; power, voltage, current and battery health.
- Fan control: fixed speed or temperature curve (Quiet / Balanced / Performance / custom), driven by CPU, GPU or the hottest sensor.
- Safety: fans return to automatic control when any CPU/GPU sensor reaches 95 °C, and whenever the helper stops.
- `thermo` command-line tool: overview, live `watch` view, JSON/CSV output, raw SMC access, fan control.
- High-temperature alerts and launch at login.
