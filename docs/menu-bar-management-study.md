# 菜单栏管理与综合工具定位

更新日期：2026-10-22。拖拽分组已完成隔离 GUI 验证；真实应用对照发现原生白名单异常，尚不能交付按组显示。

## 产品范围

用户明确希望做 macOS 综合工具，后续会有很多功能。菜单栏管理是其中一个模块。现有 `MenuBarPreferences` 和 `MenuBarData` 管理 Thermo 自身的图标、指标及点击动作，没有隐藏其他应用图标的能力。

综合工具的入口建议采用工具搜索、收藏和分类目录。菜单栏只放收藏的动作与必要状态；各模块按需启动，权限在首次使用对应功能时请求。已有的系统监控、搜索、截图录屏、清理及应用管理共用这些入口，避免每个模块再增加一个常驻图标。

## 拖拽配置

管理窗口直接展示“显示／隐藏／始终隐藏”三列。将应用卡片拖到目标列即可保存分组；卡片右侧菜单保留键盘操作入口。分组内按应用名称展示，实际菜单栏顺序仍由 macOS 的 ⌘ 拖动调整。

拖拽只传递有版本的应用 bundle ID，使用宿主进程内可见的自定义数据类型。超过 1 KiB、版本不支持、来源已不在列表、Apple 系统项目或宿主自身的载荷均被拒绝，不改已有分组。未运行的已保存应用仍可配置。

分组保存在 `UserDefaults` 的 `menuBarSections.v1` 中。拖动不会自动启用原生隐藏或请求辅助功能权限；临时展开也不会改写分组。用户已澄清配置方式是“拖拽”，此前误加的插件宿主、扩展设置入口和配置依赖已移除。

启用管理并配置隐藏项目后，Thermo 原生菜单提供“展开隐藏组／收起分组”，每次打开菜单按当前状态更新。该动作只切换临时显示，不改分组，也不启用已关闭的管理。“恢复全部图标”在管理启用或会话仍需恢复时保留；始终隐藏组通过此入口临时恢复。

## 参考产品

| 产品 | 本次确认的定位 | 借鉴内容 |
| --- | --- | --- |
| [Ice](https://github.com/jordanbaird/Ice)／[Ice 2](https://github.com/teddychan/ice-2) | 专门管理菜单栏；新版有针对 macOS 27 的实现 | 显示、隐藏、始终隐藏三组；临时展开与保存分组分开 |
| [Hidden Bar](https://github.com/dwarvesf/hidden) | 通过分隔符收起菜单栏图标 | 简单的首次使用引导、Command 拖动及一键展开 |
| [Bartender](https://www.macbartender.com/) | 菜单栏管理、搜索、快捷键及条件触发 | 刘海下的访问方式、图标搜索、按情境显示 |
| [Supercharge](https://sindresorhus.com/supercharge) | 集合 Finder、窗口等 macOS 增强功能 | 每项独立启用，让用户选择需要的功能 |
| [Almighty](https://indiegoodies.com/almighty) | 集合多种系统配置与工具 | 分类、收藏、统一查找工具的入口 |
| [OnlySwitch](https://github.com/jacklandrin/OnlySwitch) | 综合菜单栏控制工具 | 控制项、系统状态、快捷指令共用一个入口 |

以上是官方说明与源码调研，没有安装这些产品进行操作验收。对 `ShelterBar`、`Shelter Bar` 加 macOS、menu bar、菜单栏等关键词的公开检索，尚未确认用户所指产品；不能据此断言它不存在，也不将其他产品当作它。

## macOS 27 的实现边界

本机实际系统为 macOS 27.0.1（26A434）。不能只完成旧系统分隔符功能便认为满足本机需求。

Ice 2 的[原型记录](https://github.com/teddychan/ice-2/blob/main/docs/testing/macos27-prototype.md)与[集成记录](https://github.com/teddychan/ice-2/blob/main/docs/testing/macos27-integration.md)说明：旧有每个图标对应窗口的模型在其 macOS 27 测试环境中失效。新版使用 Accessibility 发现应用，并通过运行时加载 `MenuBarClientCore` 的私有 assertion 控制显示；按 bundle 管理，不能保证同一个应用的多个图标独立隐藏，也不能直接恢复旧式逐图标捕获、移动和面板能力。

该路径还有系统项目可能随 assessment 模式一起隐藏的副作用。Thermo 若采用，必须实际核对系统图标，并在激活失败、超时、退出、睡眠和权限撤销时恢复显示。不能以私有类或 selector 存在证明可用。

[MenubarHide](https://github.com/junior-rj/menubar-hide)提供另一条公开状态项路线：其 macOS 27 实现通过多个受限宽度的 spacer 将项目挤入系统 overflow，而不是单个 10,000 点分隔符。它与原生按应用隐藏的语义不同。需要对比刘海、窄屏和多屏表现，再决定是否适合作为 Thermo 的折叠方式，不能将 overflow 当成三组逐应用管理。

公开接口的三组折叠原型目前独立于 ThermoApp，尚未接入安装版。`scripts/verify-menu-bar-fold.py --output /absolute/new-directory` 构建隔离 App 并运行核心测试；普通启动全部展开，收起和展开隐藏组只改变两个分隔区的状态项宽度，关闭窗口会移除所有测试项。三个临时图标 TV、TH、TA 属于同一进程，用于验证按位置管理同一应用的不同图标。不会把既有按应用分组设置转换成物理位置。

`MenuBarOverflowPlan` 根据最窄显示区域限制每个状态项，最多为每组分配六个补充项，组合宽度覆盖最宽显示区域。屏幕记录无效或该数量不足时保持全部展开。宽度阈值来自上游 macOS 27 的经验测量，模型测试只能验证计算和边界，不能代替当前系统的实际折叠验收。

首次隔离构建通过 23 项核心测试，其中新增 4 项几何测试。只读主屏截图显示 TV 在菜单栏上，其余新测试项已经进入系统溢出区；该初始布局不足以证明三组切换。尚需在实际菜单栏中用 ⌘ 拖拽配置测试项，核对收起、展开隐藏组、恢复全部和重启。未据此替换原生后端。原型及当前验收边界见 [公开接口折叠收据](measurements/menu-bar-fold-2026-10-22.json)。

紧凑原型将 TV 合并为切换按钮，三个测试图标各占 14 点、分隔符各占 6 点，减少一个可见测试项。R2 构建通过同一组 23 项测试；主屏仍仅见 TV，缩小尺寸未解决初始位置与溢出问题。测试项已移除，拖拽配置和三组切换继续保持未验收。见 [紧凑布局对照](measurements/menu-bar-fold-compact-2026-10-22.json)。

实现应把持久分组、临时展开状态、系统能力与实际应用结果分开。应用身份不能依赖一次进程的 PID 或伪造窗口 ID。未识别的新应用默认显示；保存但未运行的应用仍能编辑；不支持单项控制的系统图标单列说明。

## 实现与验收顺序

1. 在本机做隔离探针，先验证发现、隐藏测试项目、恢复测试项目。使用独立 bundle ID，不替换安装版、不改变现有分组；同时观察系统图标副作用。
2. 实现稳定身份、三组保存、临时显示隐藏组、显示全部及一键恢复。macOS 27 按应用分组的限制要直接显示在编辑界面。
3. 接入统一工具入口与可编辑分组列表。先确保真实菜单栏里的项目可访问，再实现经验证可行的面板、搜索、快捷键和自动收起。
4. 验证刘海、多屏热插拔、Spaces、睡眠唤醒、权限撤销、应用退出及新应用启动。失败须显示原因并恢复可访问状态，不能只翻转按钮。
5. 核对常驻采样、事件监听与定时器：关闭模块后停止工作；截图和 Accessibility 权限互相独立，不为普通收起功能预先请求全部权限。

自动化检查覆盖分组规则、未知身份、持久化、过期异步回调、超时和恢复。GUI 验收须证明实际图标消失、可重新访问、退出后恢复；纯模型测试或窗口树变化不足以证明像素级效果。

## 品牌提案

建议改显示品牌。Thermo 的语义集中在温度，难以表达综合工具。先选主品牌，温度和风扇保留为系统监控模块；不让主品牌绑定 Bar、Clean 或 Capture。

暂定候选方向是 **Maclio**：短、可读，不限定具体功能；本次关键词检索未确认同名工具产品，但这不证明商标、域名或商店名称可用。正式选定前仍需查重。中文可以另取独立名称，不必音译。

改名应作为单独变更审查。当前 `Resources/Info.plist` 的标识为 `dev.thermo.app`，显示名为 Thermo；helper 标识为 `dev.thermo.helper`，构建脚本绑定现有签名及 Sparkle 账户。优先保持这些身份、偏好与更新验证连续，只改用户可见品牌；DMG、App 路径、登录项、安装器、Homebrew cask、更新源旧地址和权限继承分别做升级验收。显示名改变不等于完成迁移。

## 当前证据与未完成项

当前有 `MenuBarCore` 分组与会话控制、运行时 Objective-C 桥接及三列拖拽窗口。菜单和设置均直接进入菜单栏管理。原生隐藏默认关闭；请求失败、超时、权限撤销或退出会请求恢复，恢复异常时保留句柄供再次恢复。

`scripts/verify-menu-bar.py --output /absolute/new-directory` 从实际源码构建独立预览并运行核心测试，保存输入哈希、日志和能力探针。普通预览用于检查真实列表；Drag Check 用同目录三个测试应用的真实 bundle ID 构建隔离目录，验证拖动和保存，不启用系统隐藏，不声称验证了真实应用发现链路。所有预览使用独立 bundle ID。

本轮已通过 36 项整合定向测试，包括 19 项核心测试和 3 项应用级拖拽测试。隔离 R15 构建另运行同一组 19 项核心测试，不能相加为独立覆盖。实际 GUI 完成显示→隐藏→始终隐藏→显示的拖动；关闭重开后保留分组，落回显示组后清除覆盖项。最新构建又复核了拖动、中文界面及关闭重开。记录见 [拖拽验证收据](measurements/menu-bar-drag-2026-10-22.json)。

菜单快捷入口加入后，完整应用再次编译并通过同一组 36 项测试。R18 隔离程序执行实际 NSMenuItem 动作，核对收起→展开隐藏组→恢复全部、分组不变及关闭管理后入口撤下。测试使用未运行的临时应用身份，不创建原生隐藏会话；它验证菜单动作，不验证图标画面。记录见 [菜单快捷动作收据](measurements/menu-bar-quick-controls-2026-10-22.json)。

原生可见性另用 Visual Check 检查：测试会话暂时限制第三方图标，为测试图标留出显示空间，45 秒自动请求恢复，也可随时结束。只操作显示会话，不写真实应用分组，不退出真实应用。已观察到第三方图标实际消失及结束会话后恢复；将已安装 Thermo 加入白名单后，其图标仍显示。三个临时图标即使列入白名单仍未取得可见画面，完整三组效果尚未验收。系统设置确认临时 App 允许显示；开发者签名、短标识和固定图像标记对照也未解决这一缺口，不能据此宣布按应用隐藏可用。

AX 应用代理节点在请求期间仍可能存在，原有“节点消失”自检不能作为像素级可见性的证明。Visual Check 仅记录请求和回调，不自动认定验收通过。普通 LaunchServices 预览无辅助功能权限；shell 探针继承现有上下文而显示已授权，两者分别记录。

系统“截屏”工具提供了实际桌面画面，补上了单应用窗口截图无法覆盖菜单栏的缺口。当前连接两块显示器，另一块处于全屏终端；以下结论仅针对有菜单栏的主屏。截图留在本地隔离产物中，未加入 Git。

真实对照中，微信工具版设为隐藏、Bitwarden 设为始终隐藏：收起后二者均消失，恢复全部后二者返回；但展开隐藏组时，微信工具版仍未出现。交换分组后，Bitwarden 位于白名单时可见，微信工具版仍隐藏。该轮记录确认请求包含 Bitwarden、Thermo 及未分组的 Performance QA 标识，且排除了微信工具版；Performance QA 图标仍随会话消失。微信工具版的签名标识与 bundle ID 一致，不能用两者不一致解释。

这证明接口对部分实际应用可用，也证明“在白名单中”不足以保证图标显示。微信工具版使用 ad hoc 签名，Bitwarden 使用 App Store 签名；签名、安装位置或系统注册信息是否是原因尚未证实。此前开发者签名的临时图标也未解决问题，不能据此直接将问题归因于 ad hoc 签名。飞书宿主与 Bitwarden 的另一轮对照只取得收起主屏画面；展开时只保存到无菜单栏的全屏显示器，结果不足以验收。

管理窗口已直接提示显示组应用也可能被隐藏，并保留恢复全部入口；默认关闭不变。R22 从实际源码构建，19 项核心测试通过，提示在实际窗口中可见且三列完整。实际应用验收使用独立 App 和本地分组值，不写真实分组、不退出真实应用，均已结束。收据见 [真实图标对照记录](measurements/menu-bar-native-2026-10-22.json)。

对照阅读了 [Ice 2 的集成记录](https://github.com/teddychan/ice-2/blob/main/docs/testing/macos27-integration.md)及 [Dimble 的运行时桥接](https://github.com/fif7y/dimble/blob/main/Packages/PelmetEngine/Sources/PelmetEngineObjC/MBAssessmentShim.m)。调用形态与当前桥接一致；上游记录不能代替本机 macOS 27.0.1 的兼容性证明。下一步需查明白名单匹配身份与临时/改包应用的差异。

本机静态分析进一步定位到 AppKit 的 `NSStatusItemHost`：创建宿主时，从 scene 客户端的 audit token 构造 `BSProcessHandle`，读取并保存其 `bundleIdentifier`。MenuBarAgent 的另一个窗口身份路径会查询 LaunchServices。它们与 `NSRunningApplication` 是不同读取路径，但只读实测中，微信工具版、Bitwarden 和 Thermo 的公开 bundle ID、LaunchServices 记录、BSProcessHandle 记录、audit-token handle 记录及签名标识均一致，不能据此加入别名映射，也不能断言 ad hoc 应用都不支持。

可复现的只读检查如下；它只查指定的运行中应用，不创建状态项、不激活隐藏、不请求权限。输出的 `terminatedDuringRead` 为真时，该行不能用于判断实时身份差异。

```sh
identity_work=$(mktemp -d /tmp/thermo-menu-identity.XXXXXX)
clang -Werror -Wno-deprecated-declarations -fobjc-arc \
  -framework AppKit -framework ApplicationServices \
  scripts/menu-bar-identity-probe.m -o "$identity_work/probe"
"$identity_work/probe" com.tencent.xinWeChat419WechatUse com.bitwarden.desktop dev.thermo.app
rm -r "$identity_work"
```

探针读取新建的进程 handle，不是读取 MenuBarAgent 已缓存的宿主对象。缓存值与创建时序仍未排除。隔离构建支持 `--fixture-delay 2`，只延迟 MBH 状态项，MBV、MBA 保持立即创建。R23 已构建并通过同一组 19 项核心测试，确认三个状态项都创建；当前时序对照缺少可归属于该阶段的主屏画面，仍为未验收，不能把延迟当成修复。记录及静态 Evidence ID 见 [身份排查收据](measurements/menu-bar-identity-2026-10-22.json)。

本机为 macOS 27.0.1（26A434），编译使用 Swift 6.4／macOS 27 SDK，已获用户允许本地验证。没有改全局工具链、替换安装版、改品牌标识或发布。临时会话均已恢复；系统设置只查看了菜单栏页面并返回原页面。

剩余范围：普通权限会话中真实应用的三组切换与系统图标副作用；退出、睡眠唤醒、权限撤销、多屏及刘海；旧系统后端，以及快捷键和自动收起。目标继续保持未完成。插件扩展不属于此次拖拽需求。
