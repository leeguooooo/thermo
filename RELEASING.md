# 发布流程（直接分发）

## 每次发版

1. 改版本号：`Sources/ThermoKit/Version.swift`（构建号自动取 git 提交数，必须单调递增）。
2. 在 `CHANGELOG.md` 顶部加 `## <版本>` 段落（`- ` 开头的条目会成为 Sparkle 更新说明）。
3. 提交，然后：
   ```sh
   make release      # universal + 签名 + 公证 + DMG + appcast（APPCAST_URL 默认 app.leeguoo.com/thermo/appcast.xml）
   make publish      # 上传 releases/ 到 Pages 项目 thermo-updates；对外地址是 app.leeguoo.com/thermo/*（应用中心仓库 leeguooooo/app 的 server/routes/thermo 转发）
   ```
   产物：
   - `dist/Thermo-<ver>.dmg` —— 官网下载用（已签名、公证、装订）
   - `dist/Thermo-<ver>.zip` —— 备用
   - `dist/thermo-cli-<ver>.zip` —— 单独的命令行工具
   - `releases/` —— appcast.xml、所有历史 DMG、更新说明；`make publish` 整个上传（`/download` 跳最新版；产品页在应用中心 `pages/thermo.vue`）
   - DMG 设了 immutable 缓存：**同一版本号不要重发**，有改动就升版本。
4. 打 tag：`git tag v<ver> && git push --tags`。
   然后更新 Homebrew tap：`scripts/update-tap.sh <ver>`（会核对线上 DMG 与 `releases/` 里的一致，再推到 `leeguooooo/homebrew-tap` 的 `Casks/thermo.rb`）。
   GitHub Release 也要手动建：`gh release create v<ver>`，附上 DMG、zip、`thermo-cli-macos-universal.tar.gz` 及其 `.sha256` 和 `Thermo-<ver>-SHA256SUMS.txt`。
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
- [ ] 菜单栏面板与主窗口的概览、传感器、风扇、浏览器、磁盘清理、AI 诊断、设置正常；标题指标切换生效
- [ ] ⌘1–⌘6 切页、⌘F 聚焦传感器/诊断/磁盘分类搜索、清除搜索、⌘, 打开设置、⌘A 全选、⌘W 关闭窗口可用
- [ ] 摄氏度/华氏度切换同时更新读数、温度图、提醒阈值；系统热压力与传感器温度区分显示
- [ ] 浏览器重新检查显示进度；停止后不继续转圈；关闭页面后更新清单或提示旧测量
- [ ] 清理确认列出路径；只清理部分会话、路径删除失败、取消扫描后，剩余内容和手动勾选保持正确
- [ ] 诊断扫描与修复不并行，批量修复先列出命令；正常项目的搜索结果可见
- [ ] 风扇控制：安装 helper → 设固定转速 → 曲线 → Auto；退出 App 后策略保持；`sudo launchctl kickstart -k system/dev.thermo.helper` 启动时先恢复 Auto，再恢复保存的策略；超温保护仍然有效
- [ ] 旧版本 helper 在新 App 里显示 “outdated” 并能一键更新
- [ ] DMG 在另一台 Mac 上下载打开无 Gatekeeper 警告
- [ ] 自动更新：旧版本能检测并安装新版本

## 已知限制

- Apple Silicon 的风扇写入路径未在真机验证。
- 未上架 Mac App Store：沙盒内需 `AppleSMCClient` 临时例外，且风扇控制需要 root helper，均不符合审核规范。

## 本地打包验证

正式发布前，可以将临时验证包输出到独立目录，保留现有 `dist/` 和历史发布文件：

```sh
THERMO_DIST_DIR=/tmp/thermo-verification-dist SIGN_ID=- NOTARY_PROFILE= APPCAST_URL= scripts/build.sh
codesign --verify --deep --strict /tmp/thermo-verification-dist/Thermo.app
/tmp/thermo-verification-dist/thermo --version
```

这是 ad-hoc 签名的本地验证包，没有公证、在线更新或发布步骤。生产 helper 的签名认证和跨机型验收仍需用正式构建验证。

双架构打包检查：

```sh
THERMO_DIST_DIR=/tmp/thermo-universal-verification ARCHS="arm64 x86_64" \
  SIGN_ID=- NOTARY_PROFILE= APPCAST_URL= scripts/build.sh
scripts/verify-artifacts.sh /tmp/thermo-universal-verification "arm64 x86_64"
```

验证器检查 App、独立 CLI/helper、App 内嵌 CLI/helper 的签名、请求的架构切片和最低系统版本，并检查 Sparkle 的请求架构。构建成功仍需要真实 Intel 与 Apple Silicon 机器的运行验收。

自定义输出目录在编译前校验，不能指向仓库及其父目录、源码、构建缓存、历史发布或系统目录。重新打包只替换 `Thermo.app`、`thermo`、`thermo-helper` 及同版本的 DMG / zip，保留该目录里的其他文件。

窗口布局可用只读截图核对，`--snapshot-width` 只影响 `--offscreen` 模式，且不读写已保存的窗口位置：

```sh
dist/Thermo.app/Contents/MacOS/Thermo --main --offscreen --page overview \
  --snapshot-width 800 --snapshot /tmp/thermo-overview-narrow.png
```

主窗口最小尺寸为 800×580；概览仪表在窄窗口使用两列，宽窗口使用四列。核对概览、传感器、风扇和中英文设置页的文字与控件布局。
