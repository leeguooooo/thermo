# Claude 本机只读诊断

入口：App 的隐私工具 → Claude 本机诊断，或 `thermo agents claude-local --json`。

扫描读取当前用户的 Claude 进程、指定环境字段、默认或可识别的自定义配置目录、Desktop 安装标识和 Sentry 快照。它不启动 Claude，不读取凭据文件，不运行 shell 配置，不请求账户、模型或网络接口，也不修改任何标识和设置。

结果是本地观察，不能预测封号，也不能证明服务端账户关联或实际发送了哪些信息。文件配置、launchd 环境和运行进程环境分别列出；项目及托管设置的覆盖仍未验证。进程身份在环境读取前后核对，读取不到时保留 unknown。

## 报告格式

JSON `schemaVersion: 1`，`kind: thermo.claude-local-diagnostics`，包含采集时间、平台、只读标记和逐项检查。`complete` 为 false 时不能把未覆盖项当成正常。当前不查询服务端功能开关、账户状态和实际出口，因此完整性保持 false。

每项包含 `id`、`title`、`status`、`value`、`source`、`note`。状态为 observed、missing、permission-denied、unsupported、unknown、invalid 或 limited。observed 只表示读到了本地证据。文件每个最多读取 1 MiB；拒绝非普通文件和末级符号链接。最多检查 32 个进程、16 个配置目录。

报告不包含 ID 原文或哈希、原始代理/端点 URL、用户名路径、账户信息、私有仓库地址或 Sentry 上下文值。安装标识的格式和本地相等性可以观察，但其生成方式、网络用途和远程灰度开关不能据此推断。

在 App 中点击“保存脱敏报告”，或将 CLI JSON 重定向到你选择的本地文件。用户可在 [IP Check](https://ip-check.leeguoo.com/#local-diagnostics) 主动选择报告；页面只在内存解析，不上传或保存，不修改网络评分，明确标记采集时间和用户提供的证据。超过 24 小时提示重新检查。

## 适用范围

默认配置路径和格式是检查目标，不是对所有 Claude 版本的行为保证。Desktop 版本读取安装包元数据；CLI 仅从可识别的运行中原生版本路径取版本，不执行未知 CLI。无法识别时版本为 unknown。

遥测变量的解释参考 [Claude Code 官方文档](https://code.claude.com/docs/en/env-vars)：`DO_NOT_TRACK` 使用布尔语义，其他三个退出开关以非空值请求退出，即 `0` 也可能表示退出。显示配置请求不代表验证其对已安装版本生效，也不能证明停止全部外发。关闭遥测可能影响依赖功能开关的能力。

第三方 Windows 逆向报告仅作为字段线索：[IX 的报告](https://blog.ixixix.cn/posts/claude-client-reverse-engineering/)。当前实现不把 Windows 的静态负命题当成 macOS 的运行证据。
