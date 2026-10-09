# 发布流程（直接分发）

## 每次发版

1. 改版本号：`Sources/ThermoKit/Version.swift`（构建号自动取 git 提交数，必须单调递增）。
2. 在 `CHANGELOG.md` 顶部加 `## <版本>` 段落（`- ` 开头的条目会成为 Sparkle 更新说明）。
3. 提交，然后：
   ```sh
   make release      # universal + 签名 + 公证 + DMG + appcast（APPCAST_URL 默认 thermo-updates.pages.dev）
   make publish      # 上传 releases/ 到 Cloudflare Pages 项目 thermo-updates
   ```
   产物：
   - `dist/Thermo-<ver>.dmg` —— 官网下载用（已签名、公证、装订）
   - `dist/Thermo-<ver>.zip` —— 备用
   - `dist/thermo-cli-<ver>.zip` —— 单独的命令行工具
   - `releases/` —— appcast.xml、所有历史 DMG、更新说明；`make publish` 整个上传（另生成下载页 `/`、`/download` 跳最新版）
   - DMG 设了 immutable 缓存：**同一版本号不要重发**，有改动就升版本。
4. 打 tag：`git tag v<ver> && git push --tags`。
5. 装一份旧版本，「设置 → Check for Updates…」验证能升级到新版本。

`releases/` 要长期保留（不进 git），appcast 依赖其中的历史版本；丢了就从服务器拉回来再发版。

## 一次性配置（本机已完成）

| 项目 | 位置 |
|---|---|
| 签名证书 `Developer ID Application: LI GUO (6ZPXG4KVVS)` | 登录钥匙串（建议导出 .p12 备份） |
| 公证凭据 profile `thermo`（API Key `D2CNSWHAAG`，Developer 权限） | 登录钥匙串；私钥 `~/.private_keys/AuthKey_D2CNSWHAAG.p8` |
| Sparkle EdDSA 私钥（account `dev.thermo`） | 登录钥匙串。**丢失后已发出的版本将无法再收到更新**，务必备份：`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.thermo -x sparkle-private-key.txt`，存到密码库后删除文件 |
| Sparkle 公钥 | `Resources/Info.plist` 的 `SUPublicEDKey` |
| Cloudflare token（仅 Pages 编辑，仅 Leeguooooo 账号） | `~/.private_keys/cf-thermo-pages.token`，`scripts/publish.sh` 读取 |
| 以上全部的加密备份 | iCloud `郭立的备份/thermo-signing/thermo-signing-2026-10-09.dmg`，口令在钥匙串 `thermo-signing-backup` |

完整的凭据说明和恢复步骤记在 personal-memory `tools/thermo-release.md`。

换机器：导入 .p12、`xcrun notarytool store-credentials thermo …`（见 README）、`generate_keys --account dev.thermo -f <备份文件>`。

## 发布前检查

- [ ] `make test` 全部通过
- [ ] 在 Intel 和 Apple Silicon 各跑一次 `thermo`、`thermo fans`、`thermo watch`
- [ ] 菜单栏 App：概览/传感器/风扇/设置四页正常；标题指标切换生效
- [ ] 风扇控制：安装 helper → 设固定转速 → 曲线 → Auto；退出 App 后策略保持；`sudo launchctl kickstart -k system/dev.thermo.helper` 后风扇回到 Auto
- [ ] 旧版本 helper 在新 App 里显示 “outdated” 并能一键更新
- [ ] DMG 在另一台 Mac 上下载打开无 Gatekeeper 警告
- [ ] 自动更新：旧版本能检测并安装新版本

## 已知限制

- Apple Silicon 的风扇写入路径未在真机验证。
- 未上架 Mac App Store：沙盒内需 `AppleSMCClient` 临时例外，且风扇控制需要 root helper，均不符合审核规范。
