# 模块清单与入口

`Sources/ModuleKit/ModuleManifest.swift` 定义清单格式。`module.json` 放在模块 bundle 的 `Contents/Resources/`，由内核解码并整笔校验；无效清单不会部分加载。当前 interface 为 `1`。内置模块使用同一份清单，原生界面和生命周期由 `BuiltinModule` 实现登记。

自家功能可在进程内运行，沙盒模块通过 ExtensionKit 托管界面并经权限代理请求系统能力。清单声明不等于获得系统授权，目录保护和进程保护规则始终适用。

```json
{
  "interface": 1,
  "id": "com.example.notes",
  "name": "Notes",
  "summary": "A module with a page and settings.",
  "symbol": "note.text",
  "version": "1.0.0",
  "launch": "onDemand",
  "enabledByDefault": false,
  "capabilities": [],
  "entries": [
    {"id": "home", "kind": "page", "title": "Notes", "scene": "main"},
    {"id": "recent", "kind": "page", "title": "Recent", "scene": "recent", "parent": "home"},
    {"id": "preferences", "kind": "settingsItem", "title": "Preferences", "scene": "preferences"}
  ],
  "commands": []
}
```

页面入口从清单生成。`parent` 是同一清单中的父页面 ID，缺省表示顶层；不存在的父页面、指向其他种类的父入口或父子循环都会被拒绝。子页面在侧边栏按层级缩进，进入该模块后展开。

页面可声明可选的 `navigationKey`，值为 `"0"` 至 `"9"` 中的一个字符，对应 App 内的 Command+数字导航。它与系统级全局快捷键分开。同一清单不能重复声明导航键。内核页面优先，其后按当前已开启模块的注册顺序分配；冲突的页面仍可点击，快捷键不覆盖既有绑定，设置中会说明冲突。关闭占用该键的功能后，下一项可使用该键。

`settingsItem` 声明设置中的界面场景，也必须提供 `scene`。它不会额外变成命令行或 MCP 工具。当前注册表接入了页面、页面导航及设置场景；独立的总览卡片、菜单栏自定义场景和系统级全局快捷键仍随对应功能迁移接入（#37–#41），只写清单不会自动注册系统级快捷键。其他入口种类为 `page`、`overviewCard`、`menuBarItem`、`hotkey` 和 `toolbarAction`；需要 UI 的入口提供场景，需要执行命令的入口引用清单中存在的命令 ID。

`parent` 和 `navigationKey` 都可省略，旧清单保持可读。文本通过 `localizations` 提供翻译，入口标题的键为 `entry.<id>.title`；ID、场景、层级和导航键不翻译。

命令定义位于 `commands`。可选 `cli` 指定命令路径；参数的可选 `repeats: true` 将其变为数组，必填数组至少有一项。CLI 参数校验和 MCP 输入 schema 使用同一份定义；操作确认、预演和保护规则由实现及内核继续执行。

磁盘清理的声明见 `BuiltinModuleManifests.disk`，其原生实现见 `DiskModule`。内核以通用的 `module:<id>:<entry>` 路由访问它；旧的 `disk`、`disk:home`、`disk:overview` 和分类参数由模块适配。关闭后不注册其入口和导航键；停用的等待、拒绝原因和模型释放由生命周期回调处理。
