# Mole 原生函数研究：窗口退役、退出保护与扫描并发

目标仍是 DMG 中的 Mole 1.16.0（324），主程序 SHA-256 `77702d3d4fc9269f74fbfd61f10fc63462a98da15ef45c7d303db8a06f718e4e`，选择 ARM64 切片。

本轮通过 computer-use 在 Hopper 试用版中打开原文件。界面日志确认 11 个自动分析阶段完成，显示 `Background analysis ended in 4'24`。随后通过应用自带的 `HopperMCPServer` 读取函数、伪代码、汇编与引用。**这些属于 Hopper 原生 MCP 结果，不是 REA `analyze_function` 的 Evidence。** REA 的 DMG、Mach-O 与 plist 证据仍见[总报告](mole-native-study.md)；其 Apple Events 启动入口尚未修复。

带 `-partial` 的本地文件来自后台分析期间的定位工作，不作为最终完整性依据。本报告的主要函数结果均在后台分析完成后重新读取。伪代码为反编译器输出，不是原始 Swift；Swift 异步帧、闭包、寄存器变量和重复分支尤其需要汇编佐证。

## 1. 窗口回收有退役与恢复两条路径

观察到的主链路：

```text
sub_10020e2e0
  → 统计窗口可见性和仍应保留的隐藏窗口
  → 决定是否发送 mainWindowContentRetireRequested
  → ProbeView.retireRequested
  → MainActor 包装与闭包转发
  → sub_100d10024
  → 检查 retiredHere / window / isVisible / isMiniaturized
  → 设置 retiredHere，调用 onRetire

ProbeView.windowBecameKey
  → MainActor 包装与闭包转发
  → sub_100d103d4
  → 已退役且窗口可见时，清除 retiredHere，调用 onRestore
```

### 发起端不是只写一条日志

`sub_10020e2e0` 的汇编在 `0x10020e7bc–0x10020e7c8` 将两个计数做 OR，比较是否为 0，生成 `fire`。这两个数又分别传入 `window content retire: ... visible=... reopenableHidden=...` 日志。日志是否开启有不同分支，但最终都在 `0x10020e8a8` 或 `0x10020e8c8` 按 fire 决定是否进入通知发送路径；`0x10020e908` 调用 `postNotificationName:object:`。

`sub_100d0f744` 的汇编把全局通知名初始化为 `com.tw93.MoleApp.mainWindowContentRetireRequested`。这个例子也揭示伪代码的局限：其 C 风格伪代码丢掉了 Swift 字符串构造，单看伪代码不能恢复通知名；汇编保留了字面量。

这里可确认的是“对日志对应的两个计数都为 0 才发起退役请求”。尚不能把它等同于“系统内任何窗口不可见就回收”；前面的窗口筛选函数和 reopenableHidden 的全部身份规则尚未逐一恢复。

### 接收端再次检查窗口状态

`sub_100d0fcd0` 初始化 `MainWindowContentRetirementProbe.ProbeView`，清空 onRetire/onRestore，将 retiredHere 设为 false，并向 NSNotificationCenter 注册 `retireRequested`。

`retireRequested` 在 `0x100d103c0`，经 `sub_100d10514` 和 `sub_100d12408` 进入 `sub_100d10024`。后者为 27 个基本块、924 bytes；可见逻辑包括：

- 已经 retiredHere 时不再次调用退役回调。
- 窗口存在时检查可见和最小化状态；可见或最小化窗口的对应路径不执行该退役回调。
- 符合退役分支时先置 retiredHere，再调用非空 onRetire。
- 随后建立一个带弱引用上下文的 Swift Task。该 Task 的完整续体尚未追完，不能把它直接叫作计时恢复任务。

`windowBecameKey` 在 `0x100d10500`，经闭包 `sub_100d123f0` 进入 `sub_100d103d4`。后者为 8 个基本块、300 bytes：要求 retiredHere 为 true、window 存在且 isVisible 为 true，再清除 retiredHere 并调用 onRestore。

**可学习的设计：** 发起端与接收端分别检查状态；退役去重；恢复也有条件。它把“低常驻成本”和“再次打开仍能用”作为同一个生命周期问题处理。

**仍未证明：** onRetire 的每个绑定具体释放哪些 SwiftUI/SceneKit 对象、所有缓存的实际释放量、是否存在无法重建的状态丢失。此前日志列出的纹理、图标与目录缓存还需沿回调继续追，不应提前写成实测内存收益。

证据文件位于 `dist/mole-study/`：`hopper-window-retire-assembly.json`、`hopper-retire-notification-assembly.json`、`hopper-retire-subscriber-pseudocode.json`、`hopper-retire-handler-pseudocode.json`、`hopper-0x100d10514-pseudocode.json`、`hopper-0x100d12408-pseudocode.json`、`hopper-retire-logic-pseudocode.json`、`hopper-restore-handler-pseudocode.json`、`hopper-restore-thunk-pseudocode.json`、`hopper-restore-logic-pseudocode.json`。

## 2. 风扇退出保护确实接到了取消退出

`applicationShouldTerminate:` 在 `0x10021301c`。它检查 MainActor 执行环境，再调用 `sub_100212160`。内部函数读取并重置 `AppDelegate.quitDespiteUnconfirmedFanRestore`，还读取 `ParallelsReclaimCoordinator._isRunning` 与其他退出状态，并创建异步 Task。

从“风扇恢复未确认，取消退出”日志追到 `sub_10051bc24`。函数体确实将 `FanController.isShuttingDown` 清回 false，写出该错误日志，再调用另一个内部处理函数。它的调用者 `sub_100212b88` 存在明确分支：

```text
sub_10051bc24()
[application replyToApplicationShouldTerminate:0]
后续收尾与异步续体
```

因此这项产品状态不只是资源里的提醒语：**代码中存在进入“风扇恢复未确认”的取消处理并拒绝继续退出的路径。**

边界也很具体：这个异步函数读取帧内 `0x89`、`0x8a`、`0x8b`、`0x8c` 等偏移，当前没有完整恢复它们的生产者，不能把每个 byte 擅自命名成“恢复成功”“用户强退”等源变量。也没有执行真实风扇控制或注入 helper 断联来验证故障路径。

**可学习的设计：** 系统设置的恢复不是一条尽力而为的退出日志。退出流程需要能异步等待、明确拒绝退出，并允许用户理解未恢复状态。至于“强退”与系统关机/更新重启的区别，仍要沿异步帧生产者和不同分支继续核验。

证据：`hopper-quit-info.json`、`hopper-quit-pseudocode.json`、`hopper-quit-inner-pseudocode.json`、`hopper-fan-quit-info.json`、`hopper-fan-quit-pseudocode.json`、`hopper-fan-quit-gate-pseudocode.json`。

## 3. 首轮扫描并发与 CPU 数量有关

Objective-C/Swift 类元数据直接列出 `ScannerSizeProbeExecutor` 的成员布局：maxConcurrentWorkers 偏移 16，工作队列 24，timeoutQueue 32，operation 闭包 40，lock 56，activeWorkers 64。`otool` 原始输出见 `objc-arm64.txt:3720` 附近。

从类元数据地址 `0x10107f6f8` 的引用追到 accessor `sub_1004b2e8c`，再沿调用者找到首轮 executor 初始化 `sub_1004a9894`：它创建实例，并传入队列名 `com.tw93.MoleApp.analyze-first-pass-size` 与工作闭包 `sub_1004a992c`。

实际初始化函数 `sub_1004b2868` 为 4 个基本块、876 bytes：

- 建立 NSLock，activeWorkers 初始为 0。
- 并发上限参数最低保留 1。
- 工作队列采用 utility QoS；参数至少为 2 时使用 concurrent 属性。
- 另建标签追加 `.timeout` 的 utility 队列；它没有与工作队列相同的 concurrent 属性。
- 保存传入的 operation 闭包。

首轮传入的上限来自 `sub_1004a9748`。它读取由 `sub_1004a96fc` 缓存的 `NSProcessInfo.activeProcessorCount`；乘 3、除 5，再限制在 2 到 10 之间。除法是编译器生成的乘法高位和移位序列，已用汇编核对，不能照抄反编译器那段难读的乘法表达式。

对正常正整数 CPU 数量 P，这段计算可写成 `min(10, max(2, floor(3 * P / 5)))`。例如 P=8 算得 4，P=12 算得 7，P=20 算得 10；这是静态公式示例，不是该机器上的实测吞吐。

**可学习的设计：** 首轮快速给出可用结果，可以有独立预算；工作队列的成本与超时判定的成本分开。并发上限既随硬件变化，也有固定天花板。

后续离线追踪已确认一条 executor 路径的名额申请、正常释放和超时结算，见下一节。仍未确认所有首轮任务是否都经过同一入口，以及底层 operation 内部是否还派生独立工作。不能只从构造器存在一个数字推断全应用的实际资源上限。

证据：`hopper-scanner-class-xrefs.json`、`hopper-scanner-metadata-assembly.json`、`hopper-scanner-constructor-candidate-pseudocode.json`、`hopper-scanner-constructor-pseudocode.json`、`hopper-scanner-budget-init-pseudocode.json`、`hopper-scanner-budget-init-assembly.json`、`hopper-scanner-processorcount-pseudocode.json`。

## 4. 等待超时后，工作名额仍保留到 operation 返回

本节在另一会话使用 Hopper 期间完成，未连接或操作它的文档。使用 Apple LLVM 对相同 ARM64 输入做离线反汇编，以 Mach-O 的 LC_FUNCTION_STARTS 划分函数，再用已安装的 Capstone 核对 Objective-C lock/unlock 跳板。证据来源与 Hopper/REA 分开，清单在 `dist/mole-study/offline-scanner-evidence.json`。

### 申请名额和撤回尚未派发的任务

异步入口 `0x1004a6f3c` 将 Swift self（x20）存入任务帧 `+0x158`。后续 `0x1004a7134` 从这个位置取得 executor，并读取 `+0x10` 的上限、`+0x38` 的锁和 `+0x40` 的 activeWorkers，与上一节类元数据布局对应。

在 `0x1004a71c8–0x1004a71e8`：

1. 加锁。
2. activeWorkers 大于等于上限就走另一分支；否则先加一。
3. 解锁，再检查 Task 是否已取消。

刚取得名额但尚未派发工作时，取消分支会在锁内撤回这个计数（`0x1004a71f4–0x1004a7228`）。同样，若派发前重新检查的时间预算已经耗尽，也在锁内撤回名额（`0x1004a728c–0x1004a72c0`）。这两处减一发生在实际工作加入队列之前，不应误认为“运行中的工作超时就释放名额”。

达到并发上限的分支还读取一个模式标志，存在立即返回或继续检查取消、期限并经 ContinuousClock 暂停的路径。标志的源代码名称和全部调用者尚未恢复；目前不将它命名成某个公开开关，也不声称具备公平排队保证。

### 派发后的三条结束路径

正常工作使用 `DispatchQueue.async(group:qos:flags:execute:)`，闭包跳板 `0x1004bb468` 进入 `0x1004b2bd4`。这个函数先运行 operation（经 `0x1004bcbdc → 0x1004bcbe0` 转发到传入或实例保存的闭包），operation 返回后才在 `0x1004b2c98–0x1004b2cbc` 锁住 executor，将 `activeWorkers` 减一并限制不低于 0；之后交付结果。

另外两条路径很短，可以完整读清：

| 路径 | 回调 | 实际动作 |
|---|---|---|
| 到达期限 | `0x1004bb4bc` | 设置 `(x0,w1,x2)=(0,1,0)`，直接转入结果结算 `0x1004b2d18` |
| Task 取消 | `0x1004bb4cc` | 设置 `(x0,w1,x2)=(0,0,0)`，直接转入同一结果结算 |
| operation 返回 | `0x1004b2bd4` | 先释放 executor 名额，再把真实返回值送入结果结算 |

调度函数在 `0x1004a76e4` 绑定期限回调，经 `asyncAfter` 派发；在 `0x1004a77e0` 绑定取消回调，经 `swift_task_addCancellationHandler` 注册。因此它们的身份由实际调用位置确认，表中没有把未知的返回字段擅自命名成 Swift 源变量。

**这条路径的结论：超时和取消结算本身不修改 activeWorkers；计数跟随 operation 闭包的返回。** 在这个 executor 层，等待者提前结束不会立刻让另一个工作顶替仍未返回的 operation。此前担心的“每次等待超时都释放名额，卡住的任务持续累积”没有出现在已追到的这条路径里。

这仍不是强制终止底层工作的证据。operation 内部是否另起进程、线程或其他异步工作，返回后是否还有遗留资源，需要继续追具体 operation。若所有名额都被永不返回的 operation 占住，后续测量可能得不到名额；当前代码证明了此层的限制，不保证底层工作一定能回收。

### 同一结果只交付一次

三个结束路径都进入 `0x1004b2d18`。它获取 race 对象 `+0x10` 的锁，再调用 `0x1004b3340`。类元数据将 race 的 `+0x18` 标为 settled，`+0x20` 标为 value。

`0x1004b33b0` 检查 settled；已经完成的分支不再取出可交付的 continuation。首次完成时在 `0x1004b33ec` 设置 settled、记录值，再取走 continuation。包装函数解锁后，仅在返回的 continuation 非空时调用 `CheckedContinuation.resume(returning:)`。

调度侧也覆盖结果比 continuation 注册更早到达的情况：注册时持锁检查 settled，若结果已存在，则直接用保存值 resume；否则存入 continuation。由此，超时先到、正常结果后到，以及结果先到、等待者后注册，分别有对应处理。

等待结束后的续体在 `0x1004a8d78` 移除取消处理器，随后调用 `DispatchWorkItem.cancel()`。这个 work item 来自帧 `+0x290`，对应前面创建的期限任务；正常工作走的是另一个 async closure。不能把这次 cancel 描述为强制取消运行中的体积测量。

### 对 Thermo 的具体启发

应分别建模两种寿命：用户等待结果的寿命，和实际 operation 占用资源的寿命。等待超时可以尽早返回部分结果；真实名额应跟到工作结束。正常结果、期限与取消需要共享一次结算状态，注册 continuation 时也要处理结果已经到达的情况。

验证时应让一个合成 operation 在超时之后仍阻塞，再连续提交新任务，检查真实在途 operation 数是否超过上限、是否出现双重完成；释放阻塞后再检查名额恢复。这里是由代码证据推导的验证要求，本轮没有向 Mole 注入这些测试。

离线原始材料：`offline-scanner-await-entry-chain.txt`、`offline-scanner-schedule-1004a7134.txt`、`scanner-4b0000-4b3000.txt`、`offline-1004bb468.txt`、`offline-1004bb4bc.txt`、`offline-1004bb4cc.txt`、`offline-1004bcbe0.txt`、`offline-1004b3340.txt`、`offline-scanner-resume-chain.txt`、`objc-arm64.txt`。Objective-C 跳板 `0x100d2af60`、`0x100d2d8c0` 的 selector 分别解码为 lock、unlock，避免将裸地址调用凭经验命名。

## 5. Swift 调用方确实传递身份参数

本节同样来自离线 LLVM 汇编。Swift 字段关系由发行物的 nominal descriptor、field descriptor 与 field record 恢复，不依据字符串在文件中的相邻顺序猜测。完整记录见 `dist/mole-study/deletion-caller-findings.md`。

`DeletionPathIdentity` descriptor 在 `0x100d7eebc`，字段依次包括 device、inode、fileType、appBundleIdentity，以及缓存目录标记、符号链接目标和不同归档来源的身份。`AppBundleIdentity` descriptor 在 `0x100d75014`，包括应用自身身份、mtime、元数据相对路径及身份、SHA256、签名与主程序相关字段。字段描述符只说明结构，不能单独证明每项已参与某个执行检查。

### 序列化函数与脚本参数对齐

`0x100b505d8` 是实际可定位的参数构造函数：

- `0x100b50624–0x100b50654` 将 device、inode 两个 UInt64 分别转换成十进制字符串。
- `0x100b50658–0x100b50690` 检查 appBundleIdentity 的 Optional；为空则直接返回这两项。
- 非空时再追加六项：bundle modifiedAt、metadataPath、metadataDeviceID、metadataInode、metadataModifiedAt、metadataSHA256。Date 转为 epoch Int64；缺失的 Optional 值保留为空字符串。

返回数组与已提取脚本的 `$4` 到 `${11}` 相符。这里终于能把“脚本有校验能力”和“应用会向它传参数”连接起来，但 Optional 为 nil 的合法分支也必须保留在结论中。

### 两类 trash-app 分支都使用了这个构造器

空 mode 分支在 `0x100b64308` 调用构造器，以 `[URL.path, ""]` 为前缀拼接返回数组，再构造 `trash-app` 操作名，以 30 秒超时进入 `0x100abf624`。small string 的字节内容和长度也已核对，不能仅凭函数附近出现 trash-app 文本命名此路径。

`uninstall-remnant` 分支在 `0x100b656d8` 同样调用构造器；返回项少于 8 时补空字符串，再追加额外数组，以 `[URL.path, "uninstall-remnant"]` 为前缀。后续 dispatcher 的 `0x100abf7a0–0x100abf7f8` 将操作名前置到参数数组，得到与脚本位置一致的调用形状。

**可确认：** device/inode 与可选应用语义身份经过 Swift 数组构造并送到 SudoSession dispatcher，且并非仅用于残留专用分支。补空项的代码使可选语义参数缺失时，后面的参数仍占固定位置。

### 身份来源与执行前复核

后续已追到传入值和 fallback 的分流。共同入口 `0x100b617a4` 保留调用方传来的 Optional identity。空 mode 分支优先复制 some 值；只有外层 Optional 缺失时，才调用 `0x100b4f758` 做 lstat 基础采集。基础采集器将 appBundleIdentity 初始化为空，不能把 fallback 当作自动补全全部应用语义。

空 mode 路径还会调用 `0x100b51a14`：若已有 appBundleIdentity，就重新采集当前应用身份并按比较策略验证。`0x100b51cec` 调比较包装函数；`0x100b51d1c` 在结果为 false 时转入拒绝分支，最终 caller 引用 `trash.reason.pathChangedAfterReview`。只有通过验证才保留文件系统身份并把新采集的应用语义写入后续参数。

这回答了“是否无条件用新采集值覆盖旧身份”：已追路径有明确拒绝点。但比较策略不是简单的全字段原样相等。`0x1001ef484` 有直接比较与归一化比较两条路径，归一化路径会使用 expected 的 modifiedAt 构造临时比较对象。不能据此承诺所有元数据变化都会被拒绝。

`uninstall-remnant` 同样优先继承传入 identity、缺失时 fallback，但在已追局部路径中不走同一个应用语义刷新函数。残留对象本身也可能不是 app bundle，不能把这项差别直接判为漏校验。其 owner 参数来源已追到两项数组：一个 URL.path 和一个 Optional String，与脚本 owner 路径/ID 的位置对应。

来源追踪详情：`deletion-identity-origin.md`；原始证据：`offline-deletion-origin-producers.txt`、`offline-deletion-origin-continuation.txt`、`offline-deletion-origin-compare.txt`。本轮主分析另行核对了比较返回值的拒绝跳转、caller 的 Optional 分流与 pathChangedAfterReview 字面量，以及归一化分支的 Date 拷贝。

**仍未确认：**

- 空 mode 分支对应哪些具体 UI 入口；不能将它直接等同于软件页的每一次卸载。
- 普通应用卸载的 appBundleIdentity 是否始终非空，metadataSHA256 是否始终非空。
- 最初的身份何时捕获、何时允许缺失。已追到 `+0x260` 和 `+0x258` 的 producer，但还没把更上游 frame `+0x458` 与 review UI 的数据源连接起来。
- 应用语义比较包装函数的完整兼容规则，以及实际安装脚本与包内脚本是否一致。Process 启动参数已进一步追到下一节，仍不构成完整特权安全审计。

**可学习的实现要求：** 破坏性操作的参数模型应把文件系统身份与应用语义身份分开，执行器还要明确哪些操作必须具备更强的身份。存在 Optional 字段并不意味着某种风险操作必定启用了它。若继续使用位置参数协议，需要固定 schema 并填充缺失项，避免可选信息让后续字段错位；更换成结构化协议时也应保留同样的校验要求。

证据：`offline-deletion-region.txt`、`offline-deletion-sudo-dispatch.txt`、`offline-deletion-sudo-argv.txt`、`offline-deletion-swift-fields.py`、`offline-deletion-swift-fields.txt`。本轮主分析复核了字段解析输出、两项 UInt64 转换、Optional 检查、空 mode 前缀、trash-app small string 和 dispatcher 跳转；没有运行 Mole 的删除流程。

## 6. 维护操作以固定 sudo 前缀交给 Process

从 dispatcher 创建的异步任务继续追，任务闭包最终进入 `0x100ac3ae8 → 0x100ac3b04 → 0x100ac667c`。`0x100ac667c` 将静态数组 `0x1010ab820` 与上层操作数组拼接；该静态数组有两项，原始存储解码为：

```text
-n
/Library/Mole/mole-admin
```

同一函数在 `0x100ac677c–0x100ac6798` 构造 `/usr/bin/sudo`，随后调用进程运行器 `0x100ac5db8`。因此观察到的维护调用结构为：

```text
executableURL = /usr/bin/sudo
arguments = ["-n", "/Library/Mole/mole-admin", operation, path, mode, identity...]
```

`0x100ac5db8` 实际创建 Process，将路径转成 URL，调用 `setExecutableURL:`（`0x100ac5f0c`），将 Swift 字符串数组桥接成 NSArray 并调用 `setArguments:`（`0x100ac5f34`），然后 `launchAndReturnError:`（`0x100ac6268`）。这些 selector 由对应 ARM64 跳板和 selector reference 字节解码，非依据地址位置猜名。

这里的参数通过数组传递，空 mode 和路径中的空格不依赖再拼接成一条 shell 命令。维护功能仍由 Bash 脚本实现，不能由此称为“整个应用不使用 shell”。

### 授权配置与正常运行分开

包内另有 `/etc/sudoers.d/mole`、安装成功标记 `__MOLE_INSTALL_OK__`、root:wheel / 0755 / 0440 设置和 visudo 检查，以及 `osascript ... with administrator privileges` 的安装文案。它们说明包内存在管理 helper/授权配置的安装路径；本轮没有执行安装或读取真实 sudoers 配置。

正常运行路径则固定使用 `sudo -n`。由此可以确认执行器不会靠每一项操作交互式等待密码；授权缺失或不可用时要返回失败，再由上层处理。不能从包内安装模板反推此刻用户机器上已安装、已授权或文件未被改变。

这也明确了两个权限通道：硬件控制的签名约束 XPC helper，和清理/维护使用的 sudo + mole-admin。此前对窄 XPC selector 的结论不能覆盖整个清理权限模型。

### 进程预算与退出结果

这条 trash-app 调用传入 30 秒预算。运行器使用 Date 建立截止时间，检查 Process.isRunning，并以约 0.1 秒的 sleep 间隔轮询；到期仍运行时调用 `terminate`，走独立结果路径。后续包装函数也有 `Timed out after ...` 的文字分支。

源码级别的学习要求是把启动失败、正常退出状态、运行超时和 stderr 说明分开。本段只确认所见进程处理，不把 `terminate` 当作整个后代进程树已经退出的证明；真实文件副作用和故障恢复尚未执行验证。与上一节 scanner 的 timeout/operation 生命周期一样，API 的返回状态仍需要与实际资源状态区分。

证据：`offline-sudo-async-descriptors.txt`、`offline-sudo-100ac781c.txt`、`offline-sudo-100ac7898.txt`、`offline-sudo-run-100ac667c.txt`、`offline-sudo-process-100ac5db8.txt`、`offline-sudo-prefix-and-selectors.json`，以及原始 LLVM 反汇编。长字符串中的安装模板只作为包内静态事实，未执行。

## 7. 清理模型中的身份值已追到执行器

进一步沿 DeletionExecutor 的上游追踪，已连接到 CleanViewModel 消费的 `CacheItem.pathIdentity`。这里的证据是字段描述符、字段 offset、实际值拷贝与字典查询；尚未由这些证据恢复原始 Swift 方法名或用户点击确认的确切时刻。

### 模型把不同状态分别保存

CacheItem descriptor `0x100d758fc` / field descriptor `0x100f17c94` 明确包含：

| 属性 | 当前可确认的作用范围 |
|---|---|
| pathIdentity（ordinal 16） | 后续被取出并作为执行身份传递 |
| reviewedCacheFile（ordinal 17） | 另一项可选审阅信息；对应 enum 含 browserClone、xcodeAttachment、downloadedInstaller、instrumentsTrace，不能把它叫作通用 inode 快照 |
| isSelectedByDefault / isSelected | 默认选择与当前选择分别存储 |
| isProtectedNow / selectionBeforeProtection / selectionBeforeRunning | 当前保护和此前选择分别存储；字段存在不等于已验证所有恢复选择路径 |

安全与可执行状态也不是一个扁平枚举：`CleanCandidateSafety` 为 autoClean / reviewOnly / blocked；`CleanAvailability` 为 blockedByRunningApp / blockedBySystem / immediate。界面里的 Manual 还涉及 SystemDataGuidance，不能因为四种文案就假设底层只有四个安全值。

这组结构值得独立实现时借鉴：一个缓存可以在策略上允许清理，但此刻因应用运行而不可执行；默认推荐和用户自己选中也不能混为一个状态。具体判断、取消保护后如何恢复选择，仍需检查对应赋值逻辑。

字段解析证据：`review-model-swift-fields.json`、`review-identity-models.json`、`availability-models.json`；只读解析器 `swift_fields.py` 通过 Mach-O 段映射读取 Swift nominal / field descriptor，并保留 context kind code。

### pathIdentity 的实际传递链

```text
CacheItem.pathIdentity
  → CleanViewModel 中的 (standardizedFileURL.path, identity) 列表
  → 按路径建立身份字典
  → 批量清理执行器
  → 按当前路径查字典，取出 Optional identity
  → DeletionExecutor
  → 第 5 节的身份验证、序列化与 trash-app 路径
```

可复核的拷贝位置如下：

1. `0x10042aa40` 从 CacheItem metadata `+0x50` 取得 pathIdentity 的字段 offset。身份为 none 时不加入该 tuple；some 时在 `0x10042ab24–0x10042ab34` 将模型值复制进 tuple，key 来自该 CacheItem.url 的 standardizedFileURL.path。
2. 构造出的字典保存在 CleanViewModel 异步帧 `+0x13a0`（`0x10042acd0`）。`0x10042c330` 将这个字典作为栈参数传给清理执行器 `0x10045d5d8`，后者保存到自身异步帧 `+0x3f8`。
3. `0x10045e550` 以正在处理的路径查询这个字典。getter `0x100b10928/0x100b10934` 的已留存汇编执行 String 字典查找、按 value stride 复制 DeletionPathIdentity、写入 some/none；没有在 getter 中执行 lstat。
4. 结果保留在执行器 `+0x4f8` 所指缓冲区。`0x100477440` 取出它，`0x100477480` 将它作为栈参数传入 DeletionExecutor `0x100b53b24`。
5. DeletionExecutor 对 some 输入保留复制路径，值进入其 `+0x458` 缓冲区，再连到此前已追的 `0x100b617a4` 与 trash-app 调用链。

因此可以确认：**清理执行存在消费模型持有身份值的路径，不能把它概括成执行时对所有项目临时 stat。** 同时，模型 identity 为可选值；无身份的分支与 fallback 仍存在，不能推广成“每个文件都已有审阅快照”。

当前最后的来源缺口是最初填充 CacheItem.pathIdentity 的代码，以及它与扫描发布、review 展示、用户确认之间的顺序。另一条待验链是软件页正常卸载如何填 appBundleIdentity。这些尚未由清理路径自动证明。

完整追踪说明：`deletion-review-origin.md`。原始材料：`offline-deletion-review-clean-map-build.txt`、`offline-deletion-review-clean-model.txt`、`offline-deletion-review-clean-selection.txt`、`offline-deletion-review-mapget.txt`、`offline-deletion-review-clean.txt` 和先前的 `offline-deletion-region.txt`。主分析已独立核对模型字段 offset、tuple 值复制、执行器字典查询和传入 DeletionExecutor 的寄存器/栈位置。

## 8. 交接后用 Hopper 复核的函数与比较策略

在用户确认 WeChat 会话已用完 Hopper 后，重新载入同一 Mole ARM64 文件；本次界面日志显示完整 11 阶段分析结束，用时 6 分 19 秒。原生 MCP 返回的文档列表同时包含 WeChat 和 Mole，读取时明确指定 Mole，没有关闭或修改 WeChat 文档。

### getter、采集器和候选写入已经有伪代码交叉证据

| 函数 | Hopper 信息 | 与离线结论的对应 |
|---|---|---|
| `0x100b10934` | 5 个基本块，168 bytes | 对路径 String 做字典查询、复制 value，再写 some/none；不是在 getter 内重新 lstat |
| `0x100b4f758` | 10 个基本块，924 bytes | 调用 lstat；错误或符号链接输出空身份；基础身份不主动填 appBundleIdentity |
| `0x1002c1bac` | 34 个基本块，2204 bytes | 候选规范化续体；临时 identity 为空时，把采集器的 indirect 输出直接指向 CacheItem.pathIdentity |

`0x1002c2194` 读 CacheItem metadata `+0x50`，`0x1002c21d4` 把 x8 设为输出 item 加字段 offset，`0x1002c21dc` 调基础采集器；另一分支复制提供的身份。这个写入位置已由 Hopper 汇编再次核对。

这里需要收紧“首次构造”的说法：该方法入口接收已有 CacheItem，并返回规范化后的 Optional<CacheItem>。它属于 CacheScanner 的候选处理，但尚未仅凭这些地址证明它发生在首次扫描、review 前，或动作前刷新。采集器失败后没有直接丢弃整行的新增判断，输出行仍可能存在而 pathIdentity 为空。

因此目前严格成立的是：**候选处理阶段确实有填充身份的代码，模型的非空身份也确实传到执行端；完整 UI 生命周期的时间顺序仍需发布路径证据。**

相关报告 `cache-item-identity-capture.md`；原始离线材料 `offline-cache-item-entry-prefix.txt`、`offline-cache-item-constructor.txt`、`offline-cache-candidate-publication.txt`。Hopper 记录为 `hopper-review-mapget-info.json`、`hopper-review-mapget-pseudocode.json`、`hopper-path-identity-capture-info.json`、`hopper-path-identity-capture-pseudocode.json`、`hopper-cache-normalize-info.json`、`hopper-cache-normalize-pseudocode.json`、`hopper-cache-normalize-assembly.json`。

### 应用身份的比较会按可用指纹选择策略

比较门函数 `0x1001ef714` 为 8 个基本块、160 bytes。结合 AppBundleIdentity 的字段序号，汇编中读 metadata `+0x2c`、`+0x38`、`+0x3c`、`+0x30`，分别对应 metadataSHA256、mainExecutable、codeResources、codeDirectoryHash 的可选状态。

类型引用也已核对：metadataSHA256 为 Optional<String>；codeDirectoryHash 的引用绑定到 Foundation.Data descriptor，带 Optional 后缀；mainExecutable 和 codeResources 绑定本地 `ApplicationGroupFilesystemIdentity` descriptor，带 Optional 后缀。后者包含 deviceID、inode、mtime 秒/纳秒、ctime 秒/纳秒和 size，不能仅将它描述成文件路径或图标信息。

当这个门函数返回 true 时，包装函数 `0x1001ef484` 会构造一个临时比较对象：多数数据来自 fresh 身份，modifiedAt 则取 expected 身份，随后进入同一个 comparator `0x1001f7a60`。门函数为 false 时直接比较 fresh 与 expected。Hopper 的 6 基本块伪代码与已留存汇编对此一致。

**代码事实：** 在相应指纹条件下，顶层应用目录的 mtime 差异不会独自决定比较失败；它会先被对齐后再比较。**设计意图推断：** 使用更具体的元数据、签名或文件身份来区分应用内容变化与目录自身变化，可能减少误报。尚未测量误报率，也没有核验 comparator 全部字段和所有特殊值，不能将此总结为完整安全保证。

这比“身份比较就是所有字段严格相等”更值得学习：需要先明确每个信号证明什么，再决定哪些变化应该阻止执行。仅有目录时间、只有 inode、拥有元数据 hash 或带主程序身份，不能混成同一种证据强度。

证据：`hopper-app-identity-policy-info.json`、`hopper-app-identity-policy-pseudocode.json`、`hopper-app-identity-policy-assembly.json`、`hopper-app-identity-compare-wrapper-info.json`、`hopper-app-identity-compare-wrapper-pseudocode.json`、`app-identity-policy-field-types.json`、`app-file-fingerprint-type.json`、`app-file-fingerprint-fields.json`、`arm64-indirect-symbols.txt`。

## 已验证的工具边界

Hopper 原生 MCP 此前已实际返回文档、段、引用、函数信息、汇编和伪代码。没有购买许可证，没有修改 TCC 数据库，也没有为 cmux 打开其他权限。前述主程序研究曾遇到 REA 的 Apple Events 启动问题；该条属于当时环境记录。下述 AWDL 补充已通过当前 REA 的 Hopper provider 成功读取，证据来源分别保留。

本地 `hopper_read.py` 只允许一组已核对的读取接口，不包含重命名、修改注释或执行任意代码。原生 MCP 服务偶有提前关闭连接的情况，本轮没有将空输出当成无匹配；失败的读取只在确认应用会话仍可用后重新发起。为减少连接冲突，后续应串行使用同一个 Hopper 应用。

## 9. AWDL 的关闭动作被放在持久恢复记录之后

本轮直接使用 REA 的 Hopper provider 分析已安装 Mole 1.16.0（324）的 helper。原 FAT 文件 SHA-256 为 `2f309f5f3d6f4ce416ea92cc78363ab97869771dd0817edf98849fbcc1a19e1d`；REA 验证后提取 ARM64 切片，原文件偏移 180224、长度 181840。下列地址属于该切片的虚拟地址，不可用于其他版本或架构。没有执行 Mole helper 或切换实际网络。

| 地址 | 观察与推断 |
|---|---|
| `0x10000c590` | 调用 `socket(2,2,0)` 和 ioctl `0xc0206911`，接口文字为 `awdl0`。与本地 SDK 对照，该请求是 `SIOCGIFFLAGS`；读取接口标志属于推导结论 |
| `0x10000c714` | 在写入前比较 `if_nametoindex("awdl0")` 与传入值；先读取标志、替换低位，再调用 ioctl `0x80206910`。SDK 将它定义为 `SIOCSIFFLAGS`，`IFF_UP` 为低位 |
| `0x10000ccfc` | 汇编确认 `JSONEncoder` 后以 flags `0xb01`、mode `0x180` 打开 lease 文件，再写入、fsync 和关闭。SDK 对照得到 `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`、0600 |
| `0x100004ea0` | 启动候选先调用记录读取与恢复候选，随后读取索引和标志、调用上述持久化函数，再进入 `0x100004fc0`；后者调用关闭接口的包装并再次读取。失败分支还会调用恢复候选 |
| `0x100004bf4` | 恢复候选包含索引比较、标志读取、设置、再次读取、lease unlink 和异常路径；完整错误分支及状态字段尚未全部解释 |

函数名仍是剥离后的 `sub_*`；“启动”“恢复”是根据调用顺序和数据引用作出的分析命名。Swift 寄存器打包与错误路径会被反编译器错误还原，不能把伪代码当作原源码，或据此宣称全部恢复路径可靠。helper 中还可观察到按秒开始低延迟会话、移除前结束会话的 selector，以及 lease 路径对应的 launchd PathState 文本；实际连接身份、断连、休眠与卸载闭环仍需后续追踪或设备验收。

完整 REA Evidence 本机保存在 `dist/mole-study/awdl-helper-2026-10-17/`，包含主体摘要、provider/profile、原始伪代码与汇编、调用者和局限。可移植的函数摘要与文件哈希见 [AWDL 核心记录](measurements/awdl-session-core-2026-10-17.json)。Thermo 依据公开 ioctl 和上述恢复要求独立实现，没有复制 Mole 的私有代码。
