# 截图模块验收

2026-10-22，本机 Xcode / Swift 6.4、macOS 27 SDK。

`swift test -j 4 --filter 'CaptureCoreTests|PresentationTests'` 通过：CaptureCore 14 项，App 表现层 24 项。图像测试覆盖：裁剪的坐标方向、无效裁剪、裁剪后撤销恢复标注、遮挡后 PNG 像素、各工具导出、旋转四次及镜像两次还原、撤销分支、纵横拼接逐像素还原、重复帧、长图末尾重复视口、纯色拒绝、尺寸不符和无重叠拒绝。

独立 `dev.thermo.capture-qa` 应用链接生产编辑器。最终构建的原生交互已观察到：

- 中文工具标签及矩形工具的选中状态。
- 点击旋转后尺寸从 900 × 600 变为 600 × 900；撤销后恢复 900 × 600，重做按钮可用。
- 点击 OCR 后出现可编辑的完整三行结果：`Thermo capture QA`、`截图、标注、贴图`、`OCR local recognition 12345`。

没有替换 `/Applications/Thermo.app`，没有启动 QA 应用的 root helper、更新器或 App 控制服务，没有修改用户剪贴板，也没有进行签名发布。QA 只做临时 ad-hoc 签名。

尚未验收：原生截图的权限允许/拒绝和取消路径、全屏和窗口、多屏、鼠标拖绘、剪贴板贴图与保存对话框、二维码实图、长截图实滚动。电脑控制工具在鼠标拖动时返回 `noWindowsAvailable`；AX 按钮操作和 OCR 结果回读可用，不能用这些结果替代拖绘验收。

复现 QA 构建：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path) \
python3 scripts/verify-capture-ui.py
```

脚本输出独立应用路径，不自动启动或安装。打开后可检查图像工具与本地 OCR。程序 10 分钟后自动退出。

## 快速录屏与动图导出

录制后端以 ScreenCaptureKit 提供的同一单调时钟处理视频、系统音频、暂停和停止。当前素材为实时编码的 H.264/AAC MP4；这属于快速录制，不包含普通录制所需的可编辑鼠标/键盘事件或摄像头图层。

新增编码测试直接生成真实视频与音频样本，验证：

- MP4 的静止画面延续至停止时刻；暂停中停止不计入等待时长，继续后的样本不会保留暂停空白。
- 首尾剪辑和倍速后的 MP4 可解码且时长符合预期；系统音轨在剪辑后仍存在，且可解码为 1.6 秒、非静音的 PCM 样本。
- GIF、APNG、WebP 能读出多帧、交替的红蓝内容和 0.2 秒帧间延时。
- 导出失败保留已有目标文件；成功导出可替换目标文件。
- 草稿目录权限为 0700，正常和中断标记可重新读取；无效 JSON、缺失视频和符号链接不作为草稿打开，丢弃草稿不删除符号链接指向的外部文件。

`python3 scripts/verify-capture-ui.py --recording-review` 构建录屏预览 QA：它使用生成的移动图形视频和独立草稿目录，不捕获真实屏幕，不申请麦克风或屏幕权限。QA 应用标识按输出目录生成，避免已删除临时应用的 Launch Services 缓存影响下次启动。

真实区域录制、系统声音采集、权限拒绝、多屏仍需原生验收。测试样本的系统音轨证明编码与导出链路，不证明已从系统捕获到声音。


独立恢复验证命令：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path) \
python3 scripts/verify-recording-recovery.py
```

脚本只杀死自己刚创建且确认存活的合成编码进程，不捕获屏幕或系统声音。最后一次验证在 SIGKILL 后，从原状态为 recording 的草稿解码出 160 × 120、8 秒的视频；编码器已经接收了 10 秒合成时间轴，尾部没有全部落盘。[记录](recording-recovery-validation.json) 仅证明已落盘碎片的恢复，不保证所有时长、画质和音轨组合的尾部恢复。

当前回归为 CaptureCore 28 项、App 表现层与退出保护 27 项，共 55 项。原生 QA 已观察到蓝底移动图形视频播放、中文起止字段、倍速和格式选项。播放器显式链接 AVKit，使用 AVPlayerView。

保存面板的前台交互仍待验证。探针记录显示应用 active=false、面板 key=false；目录可写，public.mpeg-4 或 WebP 类型和目标 URL 均有效，但保存按钮不可用。已切换为异步 sheet，并保留一个独立 QA 等待前台验收，没有将此流程记作通过。


## 普通录制素材与后期处理

当前普通模式保存独立 PNG/JPEG 帧、鼠标轨迹/按钮/滚轮数据和 PCM 音频。预览用 MP4 是可重建的缓存；普通模式导出 GIF/APNG/WebP 直接读取图片帧，MP4 从图片帧编码，PCM 音轨单独编码 AAC 后合并。

新增验证覆盖：暂停剔除、取消与并发收尾时保留所有已接收帧、部分写入的日志尾部恢复、拒绝损坏日志和符号链接、没有 MP4 缓存时仍可打开普通素材、裁剪方向、标注的显示时段、指针移动和隐藏、水印与进度、透明帧复用画布时无上一帧残留、WebP 半透明数据、两种 PCM 排列与左右声道、剪辑及音量、取消导出保留已有文件、10 毫秒短片不被延长到一个完整帧周期。

GIF 时间单位由 [GIF89a 规格](https://www.w3.org/Graphics/GIF/spec-gif89a.txt) 定义，WebP 使用[毫秒帧间隔](https://developers.google.com/speed/webp/docs/riff_container)。编码器按累计时间量化；本机 ImageIO 的 APNG 输出使用毫秒精度。两种来源分别导出 16 FPS、1.8 秒剪辑的 GIF/APNG/WebP，解码后总时长误差不超过 2 毫秒，首尾颜色也符合源画面。

当前回归为 CaptureCore 46 项、App 表现层与退出保护 27 项，共 73 项。原生普通录制 QA 已观察到：从独立帧生成预览，隐藏指针、加入水印、宽度裁成 50% 后实际画面更新，修改写入 edits.json，剪辑区间 0.5–2.5 秒在刷新预览后保留；标注窗口与显示时段控件可打开。鼠标拖绘和真实屏幕输入尚未验收。

普通模式的崩溃验证：

```sh
python3 scripts/verify-recording-recovery.py --mode normal --report /tmp/ordinary-recovery.json
```

验证先确认自己创建的合成录制进程已接收帧且仍存活，再发送 SIGKILL；随后读取完整日志前缀、重建 MP4 并解码。[最近记录](ordinary-recovery-validation.json) 绑定生产 CaptureCore 源码摘要。该结果不等于真实 ScreenCaptureKit 输入、音频或全部尾部都可恢复。

原生 QA 构建：`python3 scripts/verify-capture-ui.py --ordinary-review`。合成素材与草稿目录独立，不启动 helper 或录入真实鼠标、键盘、摄像头、麦克风。前台保存面板验收仍未通过，键盘/摄像头/麦克风图层也没有完成。

`855a61c` 在独立干净检出中重新编译并通过相同的 73 项测试；该检出不包含并行的菜单栏或 Spotlight 未提交改动。[普通模式验证记录](ordinary-validation.json) 同时保留集成工作区与干净检出的结果摘要。


## 摄像头和麦克风图层

独立工作区添加了独立摄像头帧、麦克风 PCM、画中画形状/镜像/位置及两路混音。采集选项默认关闭，用户点击开始后才通过 AVFoundation 申请访问；打包资源已加入摄像头/麦克风用途说明和相应 entitlement。设备授权、屏幕源枚举先于倒计时。

本次回归 80 项（CaptureCore 53、App 表现层与退出保护 27）：摄像头延迟加入及暂停对齐；隐藏、镜像、四角定位、圆形与裁剪；MP4/GIF/APNG/WebP 中的画中画像素；44.1 kHz 单声道到 48 kHz 双声道转换；48 kHz 单声道；独立两路增益、静音、剪辑与可解码音频；原始 PCM 和摄像头帧不被后期修改覆盖；旧编辑文件缺少新字段时仍可打开；损坏/符号链接摄像头可拒绝或显式隐藏后恢复主画面。

原生 QA 使用红/绿合成摄像头和合成正弦波，不启动实际摄像头或麦克风。已观察到画中画从绿左红右变为红左绿右，麦克风增益 0.25 写入 edits.json。设备权限、拒绝授权、热插拔、实际声画同步、实时摄像头预览仍待真人设备验收。合成音频可解码不代表已经录到真实麦克风。

```sh
python3 scripts/verify-capture-ui.py --av-layer-review
```

采集权限和时钟实现参照 Apple 的[媒体授权说明](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos)及[采集同步时钟](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock)。重采样使用[带输入回调的 AVAudioConverter](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)，同采样率仅做 PCM 格式转换，以免给源音轨附加尾部样本。

主线 `7689b65` 合入后，同组 80 项测试再次通过。最终 QA 使用包内 Sparkle.framework，不依赖临时工作区；未替换安装版，也未启动真实摄像头或麦克风。


## 键盘图层

采集和显示模式分别保存。采集默认关闭，开启后默认仅快捷键；普通键需显式选择“全部按键”。读键前检查安全输入，跳过 Thermo 自身窗口，使用只读 session event tap，不使用 root/HID 或按键投递 API。

6 项专项验证覆盖：未启用时不落盘、快捷键模式不保存普通输入、暂停时间剔除、取消后日志可恢复、显示过滤/位置/过期、旧数据兼容、损坏日志处理，以及 MP4/GIF/APNG/WebP 的剪辑和倍速时点。MP4 验证使用零时间容差取帧，实际检查键名框在指定帧出现和消失；不会用默认的附近关键帧替代时点验证。

合成 QA 命令：`python3 scripts/verify-capture-ui.py --keyboard-review`。该模式仅写入预设的 ⌘C、A、⌥⇧↑，不创建系统键盘监听。

事件监听依据 Apple 的[只读 tap](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions/listenonly)及[事件 tap 创建接口](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29)。实际输入监控授权、拒绝、安全输入、暂停/退出后监听移除仍待真人设备验收。

键盘图层加入后，独立工作区回归为 CaptureCore 59 项、App 表现层与退出保护 27 项，共 86 项。原生合成 QA 已观察到预设 ⌘C 出现在顶部；编辑文件保存 top=true，刷新后 0.6–2.4 秒剪辑区间保留。编辑器改为滚动布局，以免设置被窗口顶部裁切。

主线 `2d37b3c` 的干净检出重新编译并通过 86 项测试。共享缓存曾引用一个已不存在的扩展测试源文件，该次构建失败且未清理共享缓存；通过的是独立检出结果。最终合成 QA 包使用包内框架，不依赖已清理的工作区。


## 标注效果与对象编辑

加入块平均马赛克、高斯模糊、画笔/矩形橡皮擦、矩形/椭圆聚光灯与放大镜、平铺水印。对象可选择、移动、缩放、改样式、删除或全部清空，操作保留撤销/重做。普通录制的标注使用同一渲染器，参数写入 edits.json；旧数据仍可读取。

本次回归为 CaptureCore 69 项、App 表现层/退出保护/标注检查器 29 项，共 98 项，零失败。新增测试检查块平均像素、选区外不变、模糊、透明与不透明底图的局部擦除、聚光灯、放大镜、水印、对象修改与撤销、旧编辑兼容、裁剪后的坐标变换，以及导出 MP4 的效果和原始帧不变。非法参数和图像处理失败会报错，不会静默输出未处理图。

原生合成 QA：`python3 scripts/verify-capture-ui.py --annotation-review`。已观察到马赛克强度 18→36，撤销回 18、重做回 36；删除所选对象后撤销恢复图像；椭圆放大镜中条纹实际变宽。对象拖动/缩放手势和前台保存仍待验收。未使用真实屏幕、摄像头、麦克风或键盘监听。

行为参照 PixPin 官方的[马赛克](https://pixpin.cn/docs/mark/mosaic)、[橡皮擦](https://pixpin.cn/docs/mark/erase)、[聚光灯](https://pixpin.cn/docs/mark/highlight)、[放大镜](https://pixpin.cn/docs/mark/magnifier)及[水印](https://pixpin.cn/docs/mark/watermark)说明。智能擦除的离线模型、相似区域自动匹配/同步、多选仍未实现。

主线 `cedb792` 的独立干净检出重新编译并通过上述 98 项测试。临时实现与复查工作区已清理，最终合成 QA 包保留在 `/tmp/thermo-annotations-qa-final-01a/ThermoCaptureQA.app`，框架已放入包内；未替换安装版。


## 贴图分组、关闭历史与会话保存

按照 PixPin 的[分组](https://pixpin.cn/docs/pin/pin-group)和[贴图历史](https://pixpin.cn/docs/pin/base-use)行为，加入独立分组与历史、创建/切换/改名/颜色标签/排序、跨组移动、删组时迁移贴图、清空或销毁，以及最近关闭恢复。新贴图属于当前组；隐藏不算关闭，切组不把窗口记入关闭历史。

会话保存底图、可编辑标注、标题、窗口位置/尺寸、透明度、置顶、缩放/平移、锁定和阴影开关。移出屏幕的窗口可调回可视范围。原生窗口关闭前先保存，保存失败会保留窗口。PNG 和标注存为不可变快照，原子替换清单成功后才回收旧快照；失败不会提前删除上次保存的数据。进程锁与清单版本检查拒绝旧会话覆盖新状态。

当前支持最多 100 个分组、1000 张贴图，每图上限 8000 万像素及 128 MiB PNG；清单和单份标注各限 4 MiB，单图最多 1000 个标注。超限会报错，不能静默丢弃。符号链接或损坏快照会拒绝读取；分组内缺失文档不会造成半途切换。

新增测试覆盖可编辑文档/窗口状态的落盘往返、分组名称与颜色校验、独立历史裁剪、关闭/恢复/移组、未加载分组迁移后的窗口恢复、保存失败保留清单和旧快照、未提交新快照回收、拒绝符号链接和损坏数据、并发旧版本拒绝覆盖，以及显式重读已保存会话。回归为 CaptureCore 74、App 表现层/退出保护/标注/贴图会话 34，共 108 项。

原生合成 QA：`python3 scripts/verify-capture-ui.py --pin-groups-review`。已通过管理窗口恢复关闭贴图、修改标题/透明度/锁定、退出重启后恢复同一分组与状态、关闭全部后计数变为 0/1 并保留历史，以及创建带颜色标签的新分组。只读写 QA 输出目录中的独立贴图库；不启动真实截图、录制或设备监听。

窗口拖动/缩放的真实鼠标手势、屏幕断开后的布局迁移、永久销毁的原生确认流程仍待验收。分组阴影颜色、拖动排序/分组切换快捷键、贴图内部版本历史、穿透、缩略图、批量保存、类型完整的文本/文件保存仍未完成。

主线 `6efa6cd` 的独立干净检出重新编译并通过 108 项测试。最终 QA 包保留在 `/tmp/thermo-pin-groups-qa-final-01a/ThermoCaptureQA.app`，包含包内 Sparkle.framework 和独立合成贴图库；临时实现/复查工作区与旧 QA 包已清理。未替换安装版。


## 文本、文件和颜色类型

按照 PixPin 官方的[文本](https://pixpin.cn/docs/pin/text)、[文件](https://pixpin.cn/docs/pin/file)和[颜色](https://pixpin.cn/docs/pin/color)行为，贴图现在保留各自的内容类型。文件 URL 优先于剪贴板中的图像预览；颜色值可自动转成色卡，也可通过“按文本贴出剪贴板”保留为文字。

文本使用 NSTextView 选择和编辑，保留 RTF 字体/颜色；纯文本可改字体、字号、前景和背景。HTML 由非持久 WebKit 视图显示，页面脚本关闭，CSP 与资源规则阻断外链，导航代理不打开外部地址。原始 RTF/HTML 可按格式复制；HTML 编辑使用明确的“改用纯文本编辑”。生成图像副本保留原类型贴图，文本副本仅包含当前可见区域。

文件贴图保存最多 100 个文件/目录引用，保留路径和书签；支持单选/多选、复制文件 URL 或路径、默认程序打开、Finder 定位、Quick Look 预览及原生表格拖出。空选择对全部文件操作。原文件不会被备份进贴图库或被编辑；缺失文件会报错，不能将路径文字当作文件内容。

颜色支持 #RGB/#RGBA/#RRGGBB/#RRGGBBAA、逗号 RGB、rgb/rgba、hsl/hsla、hsv/hsva，含百分比和透明度。148 个 CSS 色名的 RGB 数值来自 [W3C 色名表](https://www.w3.org/TR/css-color-4/#named-colors)。格式化使用固定小数点，不受系统数字区域设置影响；当前不实现完整的 CSS Color 4 色彩空间。

类型数据与底图/标注同属不可变快照。清单中的类型标记要求对应 payload 存在，损坏内容不会被静默当作普通图像。纯文本限 1 MiB UTF-8、HTML 2 MiB、RTF 4 MiB，单份类型 JSON 限 12 MiB；超限文本编辑会保留错误并阻止关闭/退出，用户可修正或主动还原到已保存内容。

新增验证覆盖颜色输入/格式往返与非法值、RTF 字体/去链接、类型往返及旧图像兼容、缺失 payload 拒绝、文件 URL 优先级和多文件复制、编辑关闭重启、无效编辑保留已存内容并阻止关闭，以及 WebKit 真实规则编译。回归为 CaptureCore 79、App 39，共 118 项。

原生合成 QA：`python3 scripts/verify-capture-ui.py --typed-pins-review`。已观察到红色粗体与中文文本、原生局部选择“中文”、编辑写入类型快照、文件/文件夹图标和真实文件内容预览、HEX 切换 RGB、颜色图像副本；修复后的 HTML 显示红色标题与中文，可缩放，并生成包含这些像素的图像副本。

HTML 夹具包含图片、样式、iframe 与页面脚本的环回请求，服务端在前后控制请求中确认存活，未收到任何夹具资源请求；页面标题没有被脚本替换。此记录验证该夹具的运行效果。真实浏览器/办公软件的剪贴板差异、跨应用拖放、文件移动和权限变化、外部默认程序打开/定位仍待验收。

主线 `f918371` 的独立干净检出重新编译并通过 118 项测试。最终包重启后，编辑后的“Persisted typed text 中文”和 1.2 倍缩放仍保留；关闭后从历史恢复也直接显示目标文本窗口。最终 QA 保留在 `/tmp/thermo-typed-pins-qa-final-01a/ThermoCaptureQA.app`，附带独立合成文件和贴图库；临时实现/复查工作区、旧 QA 和备份包已清理，探针服务已停止。未替换安装版。


## LaTeX 数学贴图

按 [PixPin 公式贴图](https://pixpin.cn/docs/pin/latex)的行为，加入公式类型、自动识别分隔符/常见起始命令、显式按 LaTeX 贴图、编辑、独立/行内样式、字号、前景/背景、透明背景、源码/MathML/SVG 复制、SVG 另存及渲染图像拖出/副本。Word 可编辑数学对象和公式 OCR 仍未实现，不能用图像副本计作完成。

渲染采用 [MathJax 4.1.3](https://github.com/mathjax/MathJax-src/releases/tag/4.1.3) 的直接模块及 LiteDOM，在 JavaScriptCore 中执行；没有 Node、文件、网络或宿主调用接口。MathJax、SVG 字体数据和 mhchemparser 按 Apache 2.0 分发，许可证在 ThirdPartyNotices/MathJax 中。应用和独立 QA 的打包步骤复制本地资源并检查摘要。

使用独立解析器处理每个公式，宏不跨贴图共享；宏展开限制 1000 次，缓冲 32768 字符，输入限 16 KiB UTF-8。未启用 require、autoload、HTML 和 setoptions 扩展。输出 SVG 禁止活动元素、外部链接、DOCTYPE 和外部资源属性，保留数学路径及文字。输出单边不超过 8192 逻辑像素、总计不超过 1600 万逻辑像素，原生 PNG 为固定 2 倍。错误或超限会报错，不输出源代码冒充公式。

未应用的编辑和解析错误保留在编辑器中，并禁用导出和关闭。应用成功后才替换已保存的源码、样式及预览；可主动还原未保存修改。新建、显示、恢复贴图或打开管理窗口时会激活目标窗口，便于键盘编辑与保存。

本次新增 9 项测试：分隔符和普通路径区分；分式、根号、矩阵、化学式、cases、aligned、bbox、cancel 等的真实图像及 MathML 结构；颜色/透明度/背景/字号对原生像素的影响；宏上限与跨公式隔离；非法命令与过大图像拒绝；源码和样式落盘；私有剪贴板中的 SVG/MathML 表示；错误时保留原剪贴板和已保存公式。总回归为 CaptureCore 85、App 42，共 127 项。

原生 QA：`python3 scripts/verify-capture-ui.py --latex-review`。已观察到积分/分式和蓝色矩阵；缺失括号时显示解析错误、导出被禁用，修正后像素更新；字号修改写入快照。通过系统保存面板实际写入 `exported-formula.svg`，XML 根节点为 SVG，包含 3 个 path，没有嵌入位图。

构建依赖采用固定版本和锁文件，在物理临时目录中执行干净 npm ci，重新生成的 2.9 MB 渲染器与提交版本摘要一致。Node/npm 仅用于更新资源；正常运行仅加载 App 内的 JavaScriptCore 资源。旧系统、发布签名包、跨应用拖放、复杂公式兼容以及 Word 数学对象仍待后续验收。

主线 `008cb82` 的独立干净检出重新编译并通过 127 项测试。清理临时源码和全部 npm 构建依赖目录后，保留的 QA 包仍能重启恢复公式、字号 33、颜色与背景，并重新渲染字号 34。最终包、合成贴图库及实际导出的 SVG 位于 `/tmp/thermo-latex-qa-01a`；未替换安装版。临时实现/复查工作区和构建依赖已清理，并行菜单栏改动保持原样。


## 可编辑 Word 数学对象

新增“导出可编辑 Word 文档”和“在 Word 中打开可编辑副本”。导出把 MathJax 的 Presentation MathML 转为 [Office Math（OMML）](https://learn.microsoft.com/en-us/office/math/mathml)，文档内为分式、根号、上下标、积分/求和、函数、矩阵和方程数组等原生对象。没有 Word 时仍可保存 DOCX，打开动作明确禁用；不会改用其他应用打开并声称已完成 Word 验收。

运行时只使用 Swift、随包 OOXML 模板和 macOS ditto。模板由 MIT 许可的 docx-js 9.13.0 生成并固定元数据日期，干净重建的文件摘要一致；Node 只用于更新模板。包内模板与生成器锁文件均有摘要检查。Word 的显式打开动作创建独立文档副本，不覆盖用户已经编辑的文档。

转换检查 XML 命名空间、大小、节点数和深度，禁止外部实体；不认识的构造会报错，不能静默变成图片或普通文本。支持常见变体、颜色、上下标/预脚本、重音、根号、分式、矩阵、对齐标记和边框。对 MathJax 化学式用于排版的零宽幻影节点进行语义归一，使 H₂O 下标与同位素 ¹⁴₆C 仍是可见的原生脚本。复杂度量覆盖、带标号的表格及部分 enclosure 记号仍会拒绝导出。

新增 8 项专项回归，当前 CaptureCore 93、App 42，共 135 项：检查结构化对象、限值与主体、XML 转义和样式、非法输入拒绝、有效 ZIP 包、失败时保留已有文件、化学下标、同位素预脚本，以及对齐标记必须落在实际运算符的 run 上。

独立验收采用 13 个样例，覆盖分式/根号、积分、上下标、矩阵、aligned、cases、化学式、同位素、二项式、函数、重音、括号组和边框。全部通过 OOXML XSD 校验和 Pandoc 读取；LibreOffice 26.8.1 重保存后均仍含 Office 数学对象且没有绘图/图片节点。已检查整体渲染图，修复了对齐式的字面 & 和化学脚本被隐藏的问题。LibreOffice 对边框/斜删除线的显示有限；独立的 Pandoc 参考文档也出现同样现象，保留为消费者兼容性限制。

原生 QA 使用 `--word-math-review`；已通过系统保存面板写出 `exported-editable-formula.docx`，其中含原生方程数组、积分和分式，没有 media 图像，并再次通过 XSD 校验。本机未安装 Word，也没有连接的 Word 会话，未执行 Word 打开/编辑验收。插入现有 Word 文档、Word 自身的对齐/字号/边框表现、更多复杂公式仍待验收。临时 LibreOffice 使用独立配置目录，没有安装到 Applications。

复核脚本：`scripts/verify-word-interop.py` 接受合成文档目录、Office CLI、独立校验器和 Python 路径，生成结构/回读/重保存记录及供视觉检查的 PDF/PNG。其结果不等同于 Microsoft Word 的运行验收。

主线 `d8f30f6` 的独立干净检出重新编译并通过 135 项测试。移除源码工作区、Node 依赖、临时 Office 和校验环境后，独立 QA 包仍重新生成全部 13 份文档，document.xml 摘要与验收版本一致。最终包、实际保存的 DOCX、13 组结构/渲染/重保存记录位于 `/tmp/thermo-word-qa-01a`；未替换安装版。临时实现/复查工作区、旧包和 Office 镜像均已清理，并行菜单栏改动保持原样。


## 可配置快捷键与动作注册

参照 PixPin 的[动作/脚本调用范围](https://pixpin.cn/docs/configuration/script)，新增 30 个内置动作的稳定 ID，供菜单、全局热键和贴图局部键共用。覆盖截图/贴图入口、分组前后切换、显示/隐藏/恢复/关闭、当前贴图置顶/锁定/视图、图像保存/复制/识别及标注撤销等。命名动作可选择是否出现在截图动作菜单；没有快捷键时仍可作为菜单入口。

全局与贴图局部绑定分开校验，同作用域不允许重复；贴图聚焦时局部优先。全局支持 Command/Control/Option 组合或功能键，局部可用普通按键。文本编辑器中的普通字符不会被局部绑定吞掉。录制时不执行被录制的动作；按住去重，在修改动作绑定后也要等到抬键才允许再次执行。

注册采用手势租约：复用现有手势时更换动作不重复注册，新增失败先回收新增租约，保留原配置；保存失败不切换当前配置。释放不确定则冻结回调并提示重启，不显示已成功释放。沿用 Clean Screen 的 Carbon 后端及其默认校验，截图使用独立校验策略，不改变 Clean Screen 的双修饰键要求。

配置 v1 JSON 支持导入/导出，导入先生成草稿，应用才保存并调整注册。上限 128 项/64 KiB，拒绝未知动作和损坏内容；旧 v1 数据缺少菜单显示字段时仍可读取。未配置时保留两组原始默认热键。菜单后缀从有效注册读取，失败的热键不冒充当前快捷键。

新增 10 项回归；同时覆盖既有 Clean Screen 13 项，当前 CaptureCore 96、App 62，共 158 项。验证配置往返/范围/重复项、作用域优先和按住去重、动作与手势交换、注册/保存回滚、释放不确定冻结、录制不触发动作、损坏配置保持停用，以及动作对真实模型状态的影响。

原生 QA：`python3 scripts/verify-capture-ui.py --shortcuts-review`。在独立配置与贴图库中录制并注册 ⌃⌥F18，当前应用内触发能隐藏/显示贴图；局部 L 切换锁定，文本编辑中 L 正常输入，退出编辑后 K 能打开设置。实际通过保存面板导出 JSON，内容与已应用配置一致；导入会恢复草稿，停用/重新启用以及重启后的注册状态已观察到。命名菜单显示保存的名称和手势，并在恢复测试贴图后正确执行锁定动作。

跨应用测试另用独立的无业务数据辅助应用。通过当前工具向该应用定向发送组合键，没有观察到全局动作；两个进程当时均存活。此结果未证明物理全局热键路径已通过，保留为真实跨应用按键验收缺口。没有使用 CGEvent 或脚本绕过当前电脑控制工具注入全局输入。

完整 JavaScript 脚本、命令行、串行动作与截图后的处理链仍未实现。快捷键/菜单注册是它们的共用入口，不能据此宣称脚本能力完成。实际系统热键冲突、不同键盘布局、多屏与录制等动作的硬件流程也仍待验收。
