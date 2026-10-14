# 内存检测与程序归组

内存页按程序汇总，展开后保留项目和进程。内存占用采用内核的 `phys_footprint`，驻留内存单列 `ri_resident_size`。CLI 的 `thermo memory --json` 使用同一份采样和归组代码。

## 采样口径

`AgentCore/ProcessMemory.swift` 从一次 `proc_pid_rusage(RUSAGE_INFO_V2)` 调用取得 footprint 和 RSS。若调用失败，尝试读取 task 的 RSS，并标为驻留估算；都失败时为未知。组内计数口径混合时，汇总占用列显示未知，展开后分别查看；JSON 的 `footprintKB` 只有完整 footprint 采样才有值。成功读出的零与读取失败不同。footprint 不取与 RSS 的较大值，两者不相减推断某个程序的压缩量或 swap 量。

进程 footprint 是内核计入进程的内存负担，包含计入该进程的压缩内存；RSS 是驻留映射，包含共享页。因此各程序的合计不能直接对账整机物理内存。整机应用、固定、压缩、缓存与空闲数据来自 `host_statistics64`，swap 用量来自 `vm.swapusage`，内存压力来自系统 pressure level；未知压力不触发释放内存建议。

当前 swap 活动显示相邻采样的 swapins / swapouts 差值乘页大小，再除以采样间隔。首样、计数回退和超过一分钟的间隔不产生速率。保留的 swap 量不等于当前正在换页，也不据此声称某个程序导致卡顿。

## 归组和操作

`MemoryInventory` 是内存页与 CLI 共用的只读入口。当前范围是登录用户的进程，采样失败单独报告。

- 同名命令按程序汇总，工作目录作为展开详情，展示完整进程列表。
- GUI 应用及其 bundle 内 helper 计入所属应用。应用与同名 CLI 分开，并标明应用。
- 汇总记录只用于展示和历史，不能直接授权结束进程。
- 展开的项目记录保留原 PID 集合、身份和保护规则；多个项目合并展示不会扩大结束操作的范围。
- PID、UID、启动时间和可执行文件在采样时记录，执行前重新验证；读取过程中身份变化的进程跳过。

## 趋势

程序展开时显示总 footprint 曲线。项目数量、工作负载及子进程变化都可能改变曲线，增长本身不证明泄漏。

持续增长提示要求至少一小时、四个以上可比记录，当前超过 500 MiB，较低点增长至少 300 MiB 和 50%，且仍接近高点。可比记录必须是同一组 PID、启动时间和可执行文件的连续尾部；旧记录没有身份、重启、成员变化和驻留估算会中断比较。提示指向查看详情，不保证重启能释放多少内存。单纯运行时间长或占用大不产生持续增长提示。

页面打开时每五秒采样，并保留一小时的临时曲线；后台记录仍约每五分钟保存一次，磁盘历史最多保留一天。旧的项目分组历史和无身份记录不会被当成新程序汇总的泄漏证据。

## 核对依据

- [Apple：查看内存使用情况](https://support.apple.com/en-gb/guide/activity-monitor/actmntr1004/mac)
- [Apple XNU：task ledger 读取](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)

回归测试覆盖跨项目归组、操作范围、RSS 与 footprint 大小关系、读取失败、部分数据、身份变化、旧历史、swap 计数重置与可清除磁盘容量。离屏页面截图用于检查中文布局；不代表所有负载和权限环境都已经验证。
