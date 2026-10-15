# 原生厂商更新验收

本流程验证未经修改的厂商签名包，用临时副本运行 Thermo 的准备、安装和恢复代码。不会启动厂商 App，不操作现有 Applications。2026-10-16 已完成 Rectangle 2.0.2 → 2.0.3，结果见 [记录](measurements/native-vendor-update-2026-10-16.json)。

准备一个专用临时目录，放入从官方 HTTPS 来源取得的旧版 DMG、新版 DMG 和对应 feed 快照。原包必须声明 SUFeedURL 和 SUPublicEDKey，feed 必须包含可兼容的较新版及其 Ed25519 签名。不要修改或重新签名原包来满足这些条件。

先构建当前 Debug 对象，再编译显式运行的验收工具：

```sh
swift build --jobs 4
swiftc -parse-as-library -I .build/out/Products/Debug \
  scripts/verify-native-vendor-update.swift \
  .build/out/Products/Debug/CleanKit.o \
  .build/out/Products/Debug/AgentCore.o \
  .build/out/Products/Debug/ThermoL10n.o \
  -o /tmp/thermo-vendor-acceptance
/tmp/thermo-vendor-acceptance "$scratch" "$scratch/feed.xml" \
  "$scratch/old.dmg" "$scratch/new.dmg" --download
```

`scratch` 指向这次专用临时目录。验收工具在其中另建 UUID 子目录作为自己的 Home；可通过 CFFIXED_USER_HOME 为进程额外指定专用状态目录。去掉 `--download` 后不运行生产网络下载器，仍会使用本地厂商包完成签名、替换与恢复检查。feed 复查使用固定快照，不冒充实时网络故障验收。

工具检查篡改包被拒绝、原子替换成功、旧版备份一致、恢复后旧版一致、重复恢复成功，以及替换后注入失败时回滚。启用 `--download` 时，还会用生产 HTTPS 下载器下载新版并安装、恢复，核对同样的内容。所有镜像须确认已卸载，才删除自己的验收子目录；失败则保留目录并报错，先按确切镜像路径检查挂载再清理。

输出 `acceptance-result.json` 包含版本、签名团队、架构、内容 seal 和下载包 SHA-256。复制验收记录后，操作者再清理下载包与专用临时目录。单个厂商样本不能证明所有应用、证书轮换、PKG、增量包或真实运行行为。
