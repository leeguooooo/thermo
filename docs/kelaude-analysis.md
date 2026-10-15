# Kelaude Cleaner 2.3.7 分析与 Thermo 实现

分析日期：2026-10-15。仅静态读取用户提供的安装包，未启动原应用、登录其服务或执行清理。Thermo 的实现独立编写，未引入原应用代码、图标、卡密服务或更新地址。

## 样本与证据

- ZIP：`kelaude-cleaner-2.3.7-macos-intel-apple-silicon-adhoc.zip`
- ZIP SHA-256：`f0f9d08328eefe237f3fbc610981bacdad1d10eb73872ffb0e34a12476c3b626`
- 两种架构的 `Contents/Resources/app.asar` 字节相同，SHA-256：`ab44e0626f1fd2d88e76318bbed09cfaf135842b1327fdb51f1f277534927286`。
- REA `extract_artifact`：`ev_b48ca8c483f999f93ddac83a409968957059d995a5b4086c983a844ffcbc2223`。安全提取完成，无完整性矛盾。
- REA `analyze_javascript_application`：`ev_7e5b12bd6db2dfe258d712b844fe069ec7df000c346a62f04d309a64d1bc0d39`；摘要：`ev_3cd27436237412dbb7cd22dfb36d417f930dc2b64ac49283148235a89ea4188d`。读取 23 个相关文件、解析 18 个 JavaScript 文件，无解析失败。语义图受结果预算限制，覆盖不完整；未解析的动态 IPC 关系不能据此认定存在或不存在。

REA 提取后按 ASAR 文件表定位并读取以下业务模块。下面描述的是所见源码分支，未证明原应用实际运行时成功执行这些操作。

## 原包中的功能

| 入口/模块 | 所见行为 | 证据边界 |
| --- | --- | --- |
| `src/core/targets.js` 的 `getTargets` | 固定清理 `Claude-3p/ant-did`、桌面端完整数据、Code 凭据、设置、全局状态及完整配置目录；完整重置与子项互斥 | macOS 固定目录为用户目录；原包仅 Windows 接受自定义 `CLAUDE_CONFIG_DIR` |
| `src/core/discovery.js` 的 `detectDesktopDirectory` / `detectCodeDirectory` | 在发现范围内结合目录名、文件类型及结构特征识别 Claude 数据，排除部分项目配置目录 | 并非只凭名称全盘删除；未验证所有发现路径 |
| `src/core/cleaner.js` 的 `cleanTargets` / `restoreBackup` | 校验允许路径、隔离后处理、保存操作清单及部分文件备份；恢复校验身份与摘要，原位置有新数据时拒绝覆盖 | 原包完整重置和凭据不保留持久备份；部分删除不可恢复 |
| `src/core/privacy-actions.js` 的 `getBrowserProfiles` | Chrome、Edge 与 Firefox 用户配置发现 | 浏览器配置/策略是否实际生效未运行验证 |
| 同模块 `writeBrowserPolicy` | macOS 在浏览器退出后修改 Chromium Preferences，Firefox 写偏好；定位默认阻止、限制 Chromium 非代理 UDP、Firefox 关闭 WebRTC | 本地尽力设置，不能保证阻止全部网络暴露，Firefox 通话可能受影响 |
| 同模块 `clearMailCookies` / `clearClaudeEnvironment` | 清理 mail.com 域 Cookie；清理用户环境变量及部分 shell 启动脚本 | 需区分环境变量作用域，不能宣称全部环境变量消失 |
| 同模块时区、地区及 DNS 操作 | 根据出口地区同步时区/地区、恢复中国时区、刷新 DNS 缓存、打开或更改系统定位设置 | 涉及网络查询与系统授权；静态分析不能证明权限通过 |
| 同模块 `publicPrivacyActions` | macOS 隐藏 DNS 防泄漏代理/恢复、AdGuard 安装/解除管理、浏览器语言同步/恢复六项 | 这些功能主要面向 Windows，不能把打包存在视为 Mac 可用 |
| `src/renderer/index.html` | 清理、隐私设置、更新三个页面，执行前确认；含卡密入口和“防封”文案 | 本地状态变化不能证明服务端风控结果 |

## Thermo 的功能边界

独立侧栏入口为“Claude 清理”，内部包含“Claude 重置”和“隐私与网络”。可用 `Thermo --main --page claude-cleanup` 打开。

Claude 重置采用固定允许列表，展示官方 Claude 与 Claude-3p 的设备标识、数据目录，以及 Claude Code 凭据文件、设置、全局状态和 `.claude` 数据目录。默认全不选，整目录与其中子项互斥，确认框列出路径及影响，输入 `RESET` 后执行。`.claude` 和 `.claude.json` 分别选择。保留 macOS 钥匙串，不扫描项目目录或全盘搜索副本。

重置迁移到 `~/Library/Application Support/Thermo/claude-reset/<UUID>/`。这是保留原件的恢复目录，不是释放空间。恢复前再次检查运行状态、文件身份及修改情况，已有新数据不覆盖。批次清单可供应用重启后恢复；部分失败单独报告。普通 Smart Scan 的保护规则不放宽。

隐私与网络使用 macOS 能力独立实现，具体范围及限制显示在界面。系统设置项采用系统授权或打开对应设置页；浏览器配置只在退出后修改，保留恢复副本。外部出口查询由用户触发。原包的 Windows DNS 代理、AdGuard 管理流程及卡密/更新系统不移植。

## 验收范围

核心保护使用临时 HOME 与合成数据验证，包括运行中应用、扫描后变化、符号链接、重置互斥、部分失败和恢复冲突。浏览器及命令相关测试使用离线夹具/注入执行器。只读页面快照用于检查布局。没有对用户真实凭据、会话、浏览器设置、系统时区或 DNS 执行破坏性验收；浏览器实际隐私效果仍需在明确选定的测试配置中验收。

## Cookie 备份的手动恢复

备份位于 `~/Library/Application Support/Thermo/PrivacyBackups/`，每个 `cookies-<UUID>.sqlite` 附有 `.sqlite.json` 清单，记录原数据库、浏览器、配置目录、时间和 SHA-256。先核对清单、摘要及目标配置；完全退出支持的浏览器，另存当前数据库及其 WAL/SHM，再通过 SQLite 的 `.restore` 恢复到清单指定的原数据库。不要在浏览器运行时直接替换数据库文件，也不要只替换主库而沿用旧 WAL。

此备份包含整个 Cookie 数据库。恢复会回退该数据库中其他站点的 Cookie；优先在独立测试配置中核对后操作。Thermo 的“恢复上次浏览器修改”只恢复 Preferences/prefs.js/user.js，不恢复 Cookie。

## 本地验证结果

`swift test --build-system native`：546 项通过，0 失败。新增测试覆盖重置/恢复保护、界面选择互斥、浏览器设置及 Cookie 行为。原有扫描生命周期测试收窄为临时项目范围，避免外部 Go 缓存混入夹具。

本地 ad-hoc 预览 App：`dist/claude-cleanup-review/Thermo.app`，签名完整性检查通过。重置页与隐私页快照分别为同目录下的 `reset.png` 和 `privacy.png`；已检查中文布局。真实运行中的 Claude 被重置页标为锁定。验收没有执行真实数据重置、浏览器修改或系统设置修改。
