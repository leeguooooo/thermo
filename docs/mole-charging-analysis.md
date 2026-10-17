# Mole 充电控制：静态证据与实现边界

2026-10-17。Thermo 当前仍只有电池读取；充电上限未实现、未进行硬件验收。本记录确定后续实现依据，不代表功能已经齐平。

## 分析对象

实际安装的 `/Applications/Mole.app/Contents/Library/LaunchServices/com.tw93.MoleApp.systemhelper`，SHA-256 `2f309f5f3d6f4ce416ea92cc78363ab97869771dd0817edf98849fbcc1a19e1d`。从它提取的 arm64 薄片 SHA-256 `daa48c19bf4ba6a1d026c93a9f2f5ecad7ef37d30ece971ebd27ee75508e20ac`。本次没有执行 helper，也没有写电池或 SMC。

REA/Hopper profile `d6352905c74f3f51633175dc471fdfa201da7bb23e1fdf71778eab3a1d1810e4`。完整 23 条证据与关闭时快照保存在本地忽略目录 `dist/mole-study/charging-helper-yzv8yef0/`，文件为 `charging-evidence.json`、`charging-analysis.snapshot.json`。证据包 SHA-256 `68525bb477c2b41b8cfb281b8372916b6bca7e1bcc3026a56dc7097f9118d7d9`，快照 SHA-256 `f599856f0a40fd286862b41317e3543c90e5a43918a62037d54896289d3a5554`。地址仅适用于上述薄片，伪代码不是源码；涉及位值的结论使用指令及数据交叉核对。

## 已确认的 helper 路径

| 位置 | 观察 | 证据 |
| --- | --- | --- |
| `0x100001c04` | ObjC 入口 `applyBatteryChargingWithEnabled:withReply:` 转发 bool 与 reply 到 `0x100003e88` | `ev_c885faa24f3168a4d05a935325730a03b33201c2f8b857d0b5b5377389152f7a` |
| `0x10000333c` | 调用能力检测，枚举 2 返回 unsupported；对 CHTE 路径读当前禁充状态，未知或需要变化时调用 writer | `ev_ff551e9c1d0ec3b2c20b184d696209087df5e1b3c196b695331f53da874612ca` |
| `0x10000f400` | 先检查 CH0B 和 CH0C 元数据，两者长度都为 1 时选择旧路径；否则检查 CHTE 长度 4 且规范化类型为 `ui32`，失败返回 unsupported | `ev_1bde1df7eeaec702887bafc87ad01a82a9d9b6541e48c98d6009cffedb52c20c` |
| `0x10000f140` | 旧路径依次写 CH0B、CH0C：允许为单字节 00，禁止为 02；两次结果按位与，第二次调用没有因第一次失败而跳过 | `ev_88a4a858e3b13eb797556d8fef31b5c6ad0599aacf2678b3081c40bffd5bb7b7` |
| 同上与 `0x10001d7e0` | 新路径写 CHTE：允许为四字节全零，禁止为 `01 00 00 00`。Swift 静态数组对象头之后的长度和数据与指令选择的对象对应 | 上述 writer；`ev_288cf86eadda210ba92955dc7e19c8586b83d05e8f7cdc1e3ca3a0eef4cabe74` |
| `0x10000f084`、`0x1000112ac` | 当前值读取按所选路径取 CHTE，或 CH0B（读不到才取 CH0C）；按类型解释首字节非零为禁充，另有 unknown 枚举 | `ev_1712c750beeb916008ec986b3b6b9aef11ae8780d352221e6bd09993f398c890`；`ev_39897b0e686006aa2653ff5c54abc793479604c28b15c323b300c044f9bec305` |
| `0x10000f994` | 写函数查询元数据、校验长度、提交 SMC 写请求并检查返回状态；在该函数体没有看到写后重新读取数据并比较的调用 | `ev_cc7b0a59cdff29499220a6e530ddb2b97568c0c7139ef4cee1e70d30d7f6f829` |

这条 helper API 接收充电开关，不接收百分比。不能据此声称已经还原 Mole App 的百分比策略、回差、轮询、唤醒或退出恢复；这些仍需继续追踪 App 调用者和生命周期。也不能从本次 arm64 静态结果推定 Intel 支持或本机写入成功。`0x100003c48` 经进一步检查属于其他 apply 命令的处理，字符串邻接不能证明它是充电退出恢复路径。

## 其他一手实现的交叉核对

- [batt charging.go](https://github.com/charlie0129/batt/blob/4574ecb0f3b2d5f1829154a2aae89c3cc3b0b716/pkg/smc/charging.go) 使用相同两类 gate；但还包含不同的固件百分比键，不能混同为 Mole 已采用。其 Intel 常量注明尚未验证。
- [Battery Toolkit Power](https://github.com/mhaeuser/Battery-Toolkit/blob/ed3adf103abfdad53223ce6f0a764ae7163c385b/Libraries/SMCComm%2BPower.swift) 的旧路径单写 CH0C=01，与上述双键=02 不同；不能拼接成自动回退策略。[通信层](https://github.com/mhaeuser/Battery-Toolkit/blob/ed3adf103abfdad53223ce6f0a764ae7163c385b/Libraries/SMCComm.swift) 校验元数据并写后读回，明确处理既非原值也非写入值的情况。
- [bclm](https://github.com/zackelia/bclm/blob/ae2c209614755d81bf5b788513dba1d44280a6f6/README.md) 的 Intel BCLM 百分比及旧 Apple Silicon CHWA 两档是另外的机制；项目说明 macOS 15 起受 entitlement 限制。root 权限不能被当成支持保证。
- [Apple 原生 Charge Limit](https://support.apple.com/en-nz/102338) 说明 Tahoe 26.4+ Apple Silicon 的 80–100% 用户功能。本次未找到公开第三方写入 API。IOPS 的实际 charging 状态也不是本工具 gate 的所有权或配置上限。

## Thermo 后续实现与验收

能力检测应以实际键元数据和可识别值为依据，未知值、拒绝访问、缺键明确区分；不能按芯片名猜支持。分别呈现上限策略、本工具持有的禁充状态、系统实际是否充电。只复用已证实的 gate，不引入强制断开适配器的替代行为。

写入必须串行、每键读回、部分失败明确报告并有界恢复。helper 应拥有策略及租约，进程崩溃或客户端断开也能恢复本工具持有的状态；外部已持有的禁充不能当作 Thermo 所有。正常退出、禁用、卸载、更新、唤醒和重启恢复均需覆盖。完成这些模型与故障测试后，再在明确授权的机器上验证真正的暂停与恢复充电，不能用读取成功或模拟测试代替。
