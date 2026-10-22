# 截图 JavaScript 脚本

在“截图快捷键与动作”中添加动作，选择“JavaScript 截图脚本”，填写源码后应用。脚本可绑定全局/贴图局部快捷键，也可显示在命名菜单中。导入、应用和启动 Thermo 都不会自动执行脚本；点击执行或调用该快捷键/菜单才运行。

使用 Thermo 自己的 `thermo` 对象，不能原样运行 PixPin 的 `pixpin` API。当前支持同步 JavaScript 的变量、函数、条件、循环、异常、数组和对象。原生动作在应用中完成后，脚本才继续。没有 Node、浏览器、文件系统、网络或系统命令接口；这些 PixPin 能力仍需继续实现。

```js
const before = thermo.perform('status');
if (before.pins > 0) {
  thermo.perform('toggleLock');
  console.log('锁定状态已切换');
}
return thermo.perform('status');
```

截图完成后再操作新贴图：

```js
if (thermo.perform('screenshot')) {
  const text = thermo.perform('recognize');
  console.log(text);
  thermo.perform('quickSaveImage');
}
```

`screenshot` 使用截图开始时的保存/后续动作配置。默认后续动作是打开贴图；如果配置为只复制，它不会创建新贴图，之后的贴图动作会作用于当前贴图。`quickSaveImage` 使用“截图保存与后续动作”中的快速保存目录和格式，没有设置目录时会报错。

| 调用 | 返回与行为 |
|---|---|
| `thermo.perform('status')` | 返回 `{pins, capturing, group}`；贴图数量属于当前分组 |
| `screenshot`、`screenshotCopy`、`screenshotOCR`、`screenshotQuickSave` | 选择及处理完成返回 `true`，用户取消返回 `false`，失败抛异常；后三个分别使用复制图像、复制 OCR、快速保存的后续动作 |
| `recognize` | 当前图像的本地 OCR/条码文本；等识别完成才继续；没有结果或图像被修改时抛异常 |
| `pinClipboard`、`pinText`、`pinLaTeX` | 从当前剪贴板打开贴图；不支持的内容抛异常 |
| `copyImage`、`copyContent` | 复制当前图像或原类型内容；类型不符或失败时抛异常 |
| `quickSaveImage` | 保存当前贴图的合成图像，包含当前标注 |
| `closePin`、`closePins` | 分别关闭当前贴图、当前分组贴图，返回是否已关闭 |
| `showPin`、`restorePin`、`showPins`、`hidePins`、`togglePins` | 当前贴图/分组的显示、隐藏及恢复 |
| `nextGroup`、`previousGroup` | 切换分组 |
| `toggleTop`、`toggleLock`、`resetZoom`、`rotate`、`flip`、`undo`、`redo` | 当前贴图的状态及图像编辑；不适用时抛异常；空撤销/重做栈不修改图像 |
| `pinGroups`、`shortcutSettings`、`saveSettings` | 打开相应管理窗口，打开后返回；不等用户关闭窗口 |
| `console.log(...)` | 输出到设置窗口中的脚本结果区 |

除表中另列返回值外，同步动作完成返回 `true`。顶层 `return` 可返回 JSON 兼容值；没有返回值时为 `null`。返回 Promise、循环引用或过大的结果会报错。执行异常会停止后续语句，脚本也可用 `try/catch` 处理原生动作错误。

当前不支持 `openImage`、`saveImage`、`scrolling`、`recording`、`recordingDrafts` 的同步脚本调用，也不支持递归执行 `script`；调用时明确报错。手动保存面板、长截图和录屏不能通过“启动了界面”冒充脚本动作已完成。

每次调用创建独立的 `thermo-capture-script` 进程，使用系统 JavaScriptCore。脚本源码限制 16 KiB，每次最多 1000 次原生调用；返回值最多 32 KiB，日志最多 256 条，过长日志会截断，过量输出会停止执行。默认墙钟上限 300 秒；子进程设有 10 秒 CPU 时间限制，应用以 50 毫秒周期检查 256 MiB 常驻内存上限。内存检查允许采样间隔中的短时超出，不是操作系统级内存沙箱。

“取消截图脚本”会终止脚本进程，并取消正在等待的截图或 OCR 请求。OCR 的底层计算和已经开始的同步写入可能继续收尾，但取消后不会执行后续脚本动作。已经完成的复制、保存和贴图修改不会回滚。脚本成功返回前会刷新贴图库；错误路径也尝试保留已完成的修改。

完整 PixPin 脚本 API、预设/直接区域截图、文件列表/选择文件、系统命令、翻译、CLI 及更多录屏控制仍待接入。真实截图权限、系统选择器取消、不同键盘布局与跨应用物理热键仍需实机验收。
