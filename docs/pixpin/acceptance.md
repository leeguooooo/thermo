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
