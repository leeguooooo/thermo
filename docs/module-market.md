# 模块市场（#49）

第三方模块是 WebAssembly 模块（#30 的决定），在 `ThermoWasmRunner` 沙盒里运行（#46），只能使用清单里声明的能力。原生第三方模块不分发。

## 安装包 `.thermomodule`

一个 JSON 文件：`format`（`dev.thermo.module-package`）、`version`、`keyID`、`manifest`（module.json 原始字节的 base64）、`wasm`（base64）、`signature`。

签名是 Ed25519，签的是内容摘要：

```
dev.thermo.module-package/v1
manifest-sha256:<module.json 字节的 sha256>
wasm-sha256:<module.wasm 的 sha256>
```

改动清单或代码中的任何一个字节，或者把别的模块的代码配上这份清单，签名都不再成立。上限：安装包 24 MB，wasm 16 MB，清单 256 KB。

App 安装前会检查：
1. 下载内容的 sha256 和列表里的一致；
2. 签名能用 App 内置的公钥（`ModuleSigningKeys.production`）验证；
3. 代码是 WebAssembly，清单能通过 `ModuleManifest.problems()`，id 不是 `dev.thermo.*`；
4. 清单的 id、版本和声明的能力与列表一致（用户在确认框里看到的就是模块实际得到的）；
5. 只接受更高的版本，不能降级。

需要 macOS 15 及以上，并且 App 里有 runner。

## 列表 `registry.json`

`{"format": "dev.thermo.module-registry", "modules": [{id, version, name, summary, symbol, capabilities, size, sha256, url}]}`。列表本身不签名，也不被信任，只用于展示；非 https、重复 id、`dev.thermo.*`、版本号格式不对的条目会被丢弃。

## 流水线

模块源码通过 PR 提交到模块仓库，审核看的是源码和清单里声明的能力。合入后 CI 从源码重新构建，用流水线私钥（仓库 secret）签名，发布安装包并重新生成 `registry.json`。工作流模板：`scripts/module-registry/build-and-sign.yml`；打包工具：`swift run ModulePack keygen|pack|verify|listing`。

## 网络出口

模块只能连接清单 `network.connect:<host>` 声明过的主机。不管清单怎么写，内核都会拒绝：非 443 端口、URL 里带账号密码、IP 地址（包括十进制和十六进制写法）、本机和局域网名称（`localhost`、`*.local`、单段主机名等），重定向到未声明的主机也会被拒。这些写法在清单里也声明不了。

## 卸载

先关闭模块，再把它的安装目录整体移到废纸篓，记入操作记录，可以撤销。WebAssembly 模块运行在纯计算沙盒里，没有自己的数据目录。

## 模块仓库的构建

模块仓库（leeguooooo/thermo-modules）的 CI 用 Thermo 源码构建 `thermo` 命令行和 `ModulePack`，再用 `thermo dev build` 把 WAT 编成 wasm。CI 的 Xcode 编不了 WasmKit，所以编译器用 wabt 的 `wat2wasm`，并且**只用默认特性**：`--enable-all` 会用 compact imports 编码导入段，WasmKit 不认，模块装上后会加载失败。
