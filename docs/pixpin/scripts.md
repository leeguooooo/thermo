# 截图 JavaScript 脚本

在“截图快捷键与动作”中添加动作，选择“JavaScript 截图脚本”，填写源码后应用。脚本可绑定全局/贴图局部快捷键，也可显示在命名菜单中。导入、应用和启动 Thermo 都不会自动执行脚本；点击执行或调用该快捷键/菜单才运行。

使用 Thermo 自己的 `thermo` 对象，不能原样运行 PixPin 的 `pixpin` API。当前支持同步 JavaScript 的变量、函数、条件、循环、异常、数组和对象。原生动作在应用中完成后，脚本才继续。没有 Node、浏览器、文件系统、网络或系统命令接口；这类非核心扩展保留差异，不在当前截图稳定性工作中继续实现。

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
| `grayscale`、`invert`、`brightnessUp`、`brightnessDown`、`resetImageAdjustments` | 调整当前图像底图颜色；仅图像贴图，锁定时抛异常；亮度每次增减 10%，限制为 0–200%；重置只清除颜色参数，不撤销已合并的裁剪/旋转 |
| `copyImage`、`copyContent` | 复制当前图像或原类型内容；类型不符或失败时抛异常 |
| `quickSaveImage` | 保存当前贴图的合成图像，包含当前标注 |
| `closePin`、`closePins` | 分别关闭当前贴图、当前分组贴图，返回是否已关闭 |
| `showPin`、`restorePin`、`showPins`、`hidePins`、`togglePins` | 当前贴图/分组的显示、隐藏及恢复 |
| `nextGroup`、`previousGroup` | 切换分组 |
| `toggleTop`、`toggleLock`、`resetZoom`、`rotate`、`flip`、`undo`、`redo` | 当前贴图的状态及图像编辑；不适用时抛异常；空撤销/重做栈不修改图像 |
| `togglePassthrough` | 切换本应用中鼠标位置的贴图窗口；未找到时使用当前贴图。只改变临时交互状态 |
| `restoreMouseInteraction` | 恢复全部已加载贴图的鼠标交互，包括隐藏组，不要求当前贴图；先恢复内存状态，脚本末尾的其他保存错误仍可能被报告 |
| `pinGroups`、`shortcutSettings`、`saveSettings` | 打开相应管理窗口，打开后返回；不等用户关闭窗口 |
| `console.log(...)` | 输出到设置窗口中的脚本结果区 |

除表中另列返回值外，同步动作完成返回 `true`。顶层 `return` 可返回 JSON 兼容值；没有返回值时为 `null`。返回 Promise、循环引用或过大的结果会报错。执行异常会停止后续语句，脚本也可用 `try/catch` 处理原生动作错误。

当前不支持 `openImage`、`saveImage`、`scrolling`、`recording`、`recordingDrafts` 的同步脚本调用，也不支持递归执行 `script`；调用时明确报错。手动保存面板、长截图和录屏不能通过“启动了界面”冒充脚本动作已完成。

每次调用创建独立的 `thermo-capture-script` 进程，使用系统 JavaScriptCore。脚本源码限制 16 KiB，每次最多 1000 次原生调用；返回值最多 32 KiB，日志最多 256 条，过长日志会截断，过量输出会停止执行。默认墙钟上限 300 秒；子进程设有 10 秒 CPU 时间限制，应用以 50 毫秒周期检查 256 MiB 常驻内存上限。内存检查允许采样间隔中的短时超出，不是操作系统级内存沙箱。

“取消截图脚本”会终止脚本进程，并取消正在等待的截图或 OCR 请求。OCR 的底层计算和已经开始的同步写入可能继续收尾，但取消后不会执行后续脚本动作。已经完成的复制、保存和贴图修改不会回滚。脚本成功返回前会刷新贴图库；错误路径也尝试保留已完成的修改。

完整 PixPin 脚本 API、预设/直接区域截图、文件列表/选择文件、系统命令、翻译、CLI 及更多录屏控制仍待接入。真实截图权限、系统选择器取消、不同键盘布局与跨应用物理热键仍需实机验收。

## 命令行

使用包含 Capture 控制的 Thermo 应用与配套 CLI。应用须已运行；命令通过现有同用户、签名校验的应用控制通道执行，不启动 root helper。

```sh
thermo capture actions --json
thermo capture action status --json
thermo capture run --code "console.log('ready'); return thermo.perform('status');" --json
thermo capture run --file ./capture.js --json
thermo capture action screenshotCopy --json
```

`capture actions` 列出动作 ID 和 `scriptSupported`。`capture action` 调用一个同步脚本动作；`capture run` 接受 `--code` 或 `--file`，两者只能选一个。文件须是普通 UTF-8 文件，源码上限 16 KiB。调用即执行；`--dry-run` 只核对字段、动作支持及源码大小，不运行代码、不检查 JavaScript 语法，也不请求截图权限。

CLI 默认等到操作返回，脚本的应用端墙钟上限为 280 秒，客户端默认等待 290 秒；可用 `--timeout 1…300` 调整客户端等待时间。客户端超时不会自动取消或重发原操作。错误会给出原请求 ID，使用它查询状态：

```sh
thermo capture status REQUEST_UUID --json
thermo capture cancel REQUEST_UUID --json
```

`status` 不带 ID 时读取最近一次 CLI 运行记录，没有记录时为 `idle`。`cancel` 必须指定 ID，只取消对应的活动 CLI 请求。取消回复中的 `cancelRequested` 表示已发出取消请求；用 `status` 确认最终阶段。应用保留最近 32 次已启动运行的结果；更旧的记录或重启前的记录会变成 `unknown`，不能据此认定操作没有执行。进程存续期间，已收过的运行请求 ID 即使结果已被移出缓存，也不能重放。

JSON 报告使用 `schema: 1`，包含 `id`、`phase`、`cancelRequested`，以及可选的 `result: {value, logs}` 和 `issue`。阶段为 `idle`、`validated`、`running`、`succeeded`、`failed`、`cancelled` 或 `unknown`。`succeeded` 表示 JavaScript 已完成；截图选择被用户取消时，截图动作的返回值仍为 `false`，不能仅凭脚本阶段认定已有截图。运行失败退出码为 3，取消为 130；正常的状态查询可返回一条 `failed` 运行记录并以 0 退出，需读取报告阶段。

请求仍受原有 64 KiB 帧上限约束。只有这五个截图控制接口的响应上限为 4 MiB，用于保留有界日志和结果；其他控制接口保持原上限。`--control-directory DIR` 可明确选择一个独立应用实例的私有控制目录，沿用所有权、路径和签名检查；正常使用不需提供。

本批没有加入 PixPin 的 `-r/-f` 兼容别名，也没有补齐文件、系统命令、直接区域、翻译及录屏生命周期 API。旧版应用收到新 CLI 请求会明确拒绝，不会把请求改为其他操作。
