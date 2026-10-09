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

所有读取命令都支持 `--json`、`--csv`，另有 `--fahrenheit`、`--no-color`（也遵循 `NO_COLOR`）。

## 风扇控制安全机制

- 只有 root helper（`dev.thermo.helper`）写 SMC；转速始终限制在 SMC 报告的 min–max 内。
- 策略由 helper 持有，CLI/App 退出后仍然生效；helper **启动、退出（SIGTERM/SIGINT/SIGHUP）时把所有风扇恢复自动**。
- 任一 CPU/GPU 传感器 ≥ 95 °C 时立即全部恢复自动并清除策略。
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

## 结构

```
Sources/CSMC/        C：AppleSMC 用户客户端、类型编解码、key 信息缓存、IOHID 温度（Apple Silicon）
Sources/ThermoKit/   传感器发现/命名/分组、Sampler、电池、风扇曲线与策略引擎、XPC 协议、helper 安装
Sources/thermo/      CLI
Sources/ThermoHelper/ root helper（LaunchDaemon + XPC）
Sources/ThermoApp/   菜单栏 App（AppKit + SwiftUI + Swift Charts）
```

调试：`Thermo.app/Contents/MacOS/Thermo --render-preview DIR` 把面板各页渲染为 PNG（AppKit 原生控件会显示为占位块）。helper 日志：`/var/log/dev.thermo.helper.log`。
