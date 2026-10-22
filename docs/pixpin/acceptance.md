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
