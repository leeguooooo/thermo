# Changelog

## 1.5.53

- 内存紧张时，内存页会按影响列出可执行的释放步骤。闲置工具副本和遗留进程可集中结束，操作前重新检查身份和所属会话；系统进程、AI 会话和 Thermo 自身不会被结束。AI 建议与本机检查不一致时会明确说明。
- App 在运行期间被更新后提示重启，并继续遵守保存和录制保护。设置和控制接口显示实际运行的代码版本，避免把磁盘上的新版误报为已运行。
- 开发构建默认输出到 dist.noindex，避免被 Spotlight 当作另一份已安装的 Thermo。

## 1.5.52

- 修复搜索预览导致 Thermo 闪退：在搜索里预览过 PDF、图片这类文件后，关掉预览窗口，Thermo 会直接退出。预览视图被关了两次，第二次触发了系统的断言。

## 1.5.51

- 智能扫描各分类页底部新增「AI 勾选」：交给这台 Mac 上的 AI（magpie、Ollama、LM Studio 或 Claude Code）逐项判断。它只勾选认为可以安全删除的项，比如很久没用、能重新生成的构建缓存；刚用过或拿不准的项不勾。每一项下面写着 AI 的判断和理由。有风险的项和保护的位置不会被勾选，按「清理」之前不会删任何东西。第一次使用时会先列出要发给 AI 的内容（只有名称、大小、上次使用时间和路径，不含文件内容），确认后才发送。

## 1.5.50

- 磁盘清理分类页：底部的「清理」作用于所有分类里勾选的项目。勾选项不全在当前页时，底部写「共选 N 项，本页 M 项」。之前在 Xcode 页也会显示「已选 5 项 · 清理 3.1 GB」，容易以为要清的是 Xcode 的东西。

## 1.5.49

- 磁盘清理分类页：搜索没有匹配时显示「没有匹配的项目」。之前扫描不完整时，搜索无结果会显示「扫描未完成」和「重新扫描」，看起来像扫描出了问题。扫描不完整的提示仍在列表上方。

## 1.5.48

- 空间去向：「增长最多」里直接放在个人文件夹下的目录（如 `.cache`），下面一行写「个人文件夹」，不再只显示一个 `~`。

## 1.5.47

- 空间去向：「工具与 agent 目录」的「清理…」改为打开完整扫描。这些目录里混着 AI 会话、模型、工具缓存和包缓存，之前按钮只进「AI 会话」，聊天记录全保留时页面显示 0 B，看起来像没有可清理的东西。

## 1.5.46

- 云析下载：继续一个已经全部下完的任务时，先在本地校验并合成文件，不再先重新打开分享、刷新文件信息或要求登录。1.5.45 只改了下载器这一层，但 App 恢复任务时会先打开分享，分享过期或没登录就在那一步报错，修复执行不到；这次补上了。

## 1.5.45

- 云析下载：所有分段都已下完并校验过的任务，恢复时直接在本地校验并合成文件，不再先去刷新下载链接。之前链接过期时，这类任务会一直停在「已暂停」，文件也一直合成不了。

## 1.5.44

- 磁盘总览：每一类后面原来只写着「可以清理」，点了也不能清理；现在改成「清理…」按钮，点一下就进入对应的清理扫描。
- 磁盘总览：「增长最多」的每一行，以及详情里「里面最大的」每个文件夹，都多了「去挑选…」按钮。点了会在空间透视里打开这个文件夹，在那里勾选要移到废纸篓的内容。

## 1.5.43

- 磁盘总览：「增长最多」每行的标题改成文件夹名，下面一行是它所在的位置，不再把同一条路径写两遍。
- 各处路径显示：个人文件夹本身也缩写成 ~，之前只缩写它下面的路径。

## 1.5.42

- 命令行：`thermo clean overview` 的「Grew since…」里的时间改用英文（如 yesterday），和其余输出一致，不再混进「昨天」。

## 1.5.41

- 磁盘总览：没有「完全磁盘访问权限」时，「增长最多」也能用。1.5.40 遇到读不了的系统目录就整次不记录，增长列表永远不出现；现在只比较测完整的目录。

## 1.5.40

- 磁盘总览：每次完整测量后，会和大约一天前的那次比较，列出增长 1 GB 以上、增长最多的目录（最多 5 个），并写明这段时间可用空间少了多少；每行可以直接在访达中打开。命令行 `thermo clean overview` 同样会显示。第一次测量只是建立基准，隔天再测才会出现。

## 1.5.39

- 设置 → 保护的位置：弹窗高度跟着条目数走，条目少时不再留下半个弹窗的空白；条目多时仍在弹窗里滚动。

## 1.5.38

- 专注计时：四个时长输入框对齐成一列；打开或关闭设置面板不会再把没改过的默认值存成你的设置。

## 1.5.37

- 磁盘总览：测量没跑完时，「未归类」会写明「这里最多 X」，不再只显示「大小不可用」；切换界面语言后，「可由系统释放」和「读不了的目录」这两条说明也不会丢。

## 1.5.36

- 专注计时（#24，感谢 @beilo）：休息到点后全屏会保留，等你选择「关闭」或「开始专注」；勾选「休息结束后自动开始专注」则直接进入下一轮。时长和长休息间隔可以直接输入数字。休息画面的按钮改成深色半透明胶囊。
- 磁盘总览：「未归类」的说明不再出现「。；」这样的双标点。
- 命令行：`thermo bench` 增加 `slowdown tick` 一行，显示卡顿诊断每轮的稳态耗时。

## 1.5.35

- 标签整理：没有暂存记录时不再显示「已保存 0 组」；「移除记录…」挪到「打开到指定窗口」同一行的右侧，颜色调淡，不和重新打开抢注意力。

## 1.5.34

- 标签整理：暂存记录可以移除了。全部重新打开后，卡片上直接有「移除记录…」；还有没打开的，按钮在「查看网址、结果和打开位置」里。记录移到废纸篓，可以放回，打开着的标签不受影响，操作记录里能看到。
- 命令行：新增 `thermo tabs forget UUID`，作用相同。

## 1.5.33

- 空间透视：首次打开时的测量提示改为「正在完整测量一次个人文件夹」，原来的写法读起来像要你先去点测量。

## 1.5.32

- 标签整理：恢复暂存页面失败时会显示原因。以前错误一出现就被列表刷新清掉，看起来像什么都没发生；暂存、分组失败也一样。
- 暂存页面原来所在的窗口已经关了时，按钮变成「重新打开 N 个页面到…」，直接选一个现有窗口，不会再点了没反应。
- 标签整理的错误提示补齐中文。

## 1.5.31

- 风扇：固定转速或温度曲线和当前设置一样时，「应用」按钮变灰，和自动模式一致；出错或被安全保护暂停时仍可重新发送。
- 操作记录：把风扇切回自动不再被记成「失败」。
- 风扇停转时的说明改为「暂停转动，需要时自动启动」：实测 CPU 70°C 左右风扇也会停，不只是机器凉的时候。

## 1.5.30

- 风扇：Apple 芯片的 Mac 凉下来时风扇会停转，概览、侧栏和风扇页现在显示 0 rpm，并注明「机器凉时风扇停转」，不再显示「—」或「未知」。

## 1.5.29

- 智能检查里没有操作按钮的问题，会直接在说明下面写出该怎么处理，不用再展开「详情」。

## 1.5.28

- 空间去向的可用空间下面会写明「另有 X 可由 macOS 按需释放」，和智能扫描首页（含可清除空间）的数字能对上。
- 残留数据因为没有完全磁盘访问权限而扫不全时，空列表会提示先授权，而不是让你重新扫描。
- 智能检查 → Agent 进程：agent 自己的程序不提供结束按钮，现在会说明原因和该去哪里退出。
- 操作记录里的文件路径用 ~ 显示；空间透视树图里窄格子的大小不再折成两行。

## 1.5.27

- 修复：辅助服务把转速限制在风扇范围内时，操作记录不再把成功的风扇改动记成失败。

## 1.5.26

- 操作记录：改风扇模式也会记下来（每个风扇设成了什么）；智能检查里删除后台任务等修复会写明是哪一项。
- 修复：标签整理里搜索后什么都没勾时，底部「预览暂存」按钮仍按全部页面计数（搜出 1 个却显示 17 个）；现在只算搜索结果里能暂存的页面。
- 恢复已暂存标签的确认框不再显示暂存时的说明；全部恢复后不再留一个灰色的「重新打开 0 个页面」按钮。
- 修复：在风扇页点「应用」后，模式选择会跳回上一次的设置（设成固定转速后显示「自动」，再点「应用」就会把刚设的改回去）。
- 修复：iOS 模拟器开着时，软件管理里所有带关联文件的应用都无法卸载（「移到废纸篓」变灰，提示无法核实已安装应用的归属）。
- CPU / GPU 占用页的程序行可以用 VoiceOver 展开查看进程了。
- 在 CPU / GPU 占用页结束或退出的程序也会出现在操作记录里。

## 1.5.25

- 风扇转速偶尔读到 0 时，侧栏和菜单栏面板的转速留空而不是显示「未知 转/分」。

## 1.5.24

- 刚启动的几秒里系统还没真正读到风扇转速时，面板、侧栏、概览和风扇页不再显示「0 RPM · 0%」，改为「—」或「未知」。

## 1.5.23

- 云析下载：打开页面时读取钥匙串里的账号和任务改在后台进行，macOS 弹出钥匙串授权框时窗口不再整个冻住。

## 1.5.22

- 菜单栏面板顶部的内存摘要英文缩短，两行放得下，不再被省略号截断。

## 1.5.21

- 侧栏间距收紧，默认窗口高度下「智能检查」不再被底部裁掉一半；市场页改名「插件市场」，和智能检查里的「插件」分开。
- GPU 页的曲线和 CPU 页一样有面积填充；CPU/GPU 曲线刚打开时横轴固定一分钟，不再挤成秒级刻度，最右边的时间标签也不再被裁掉；空闲程序的 0.0% 变灰，忙的程序一眼能看出来。
- 设置：刷新间隔显示「2 秒」而不是「2 s」；过热阈值改成左标签右数值；「AI Agent」小节标题大小写和侧栏一致。
- 软件管理：残留数据因缺「完全磁盘访问权限」扫不全时，提示旁直接有「打开完全磁盘访问权限设置」按钮。
- 清理项里的「and 1 more」「is running」等英文拼接改成中文；中文引号统一为“”。
- 智能检查：各区域的问题数标题统一为「N 个问题」；不足 1 MB 的残留进程显示「<1 MB」而不是「0 MB」。
- 菜单栏面板底栏的「菜单栏…」改成和旁边一样的图标按钮，英文界面下这一行不再超出面板宽度把左边裁掉；卡片标题和右上角数值各保持一行。
- 界面语言选英文时，日期时间按英文格式显示（Nov 6, 2026、7:29 PM），不再跟着 Mac 的中国地区显示「2026年11月6日」。

## 1.5.20

- 菜单栏面板：前台是全屏应用（比如全屏的终端或浏览器）时点菜单栏图标，面板以前会开到另一个桌面空间里，看起来像点了没反应；现在会直接出现在当前屏幕。
- 截图标注：马赛克只遮住截图内容，画的箭头、框和笔迹始终显示在马赛克上面。

## 1.5.19

- 截图选好区域后可以直接标注：工具条里有矩形、箭头、铅笔、马赛克和撤销（快捷键 R、A、P、M、⌘Z），选中工具在选区里拖动即可，完成或 ⌘C 时一起合成到截图里。不选工具时用法和以前一样。

## 1.5.18

- 长截图可以自动滚动：勾选「自动滚动」后点开始，Thermo 会自己往下滚、边滚边拼，到底自动停下；中途可以随时点停止。第一次使用需要在系统设置里允许 Thermo 的辅助功能权限。

## 1.5.17

- 搜索：第一次打开搜索时会自动加入「桌面、文稿、下载」三个文件夹，装好就能按文件名找文件（只看文件名，不读内容）。已经自己选过文件夹的不受影响，移除后也不会再加回来。macOS 可能会询问一次是否允许访问这些文件夹。
- 截图：选区时鼠标停在 Thermo 自己的窗口或贴图上，也会高亮它，点一下即可截取。
- 长截图窗口的「开始」按钮显示中文。

## 1.5.16

- 搜索：拼音首字母和英文首字母可以直接搜，xtsz 就是系统设置，gc 就是 Google Chrome，只敲前两个字母（如 xt）也会把「系统设置」「系统信息」排在前面。
- 搜索：打开搜索时底部不再一直显示「正在索引…」。应用列表的刷新从好几秒缩短到 1 秒以内，在后台悄悄完成；装有 Unity 这类大文件夹时尤其明显。
- 搜索：远程管理等藏在系统子文件夹里的应用不会再漏掉；Unity 编辑器里的打包模板不再出现在结果中。

## 1.5.15

- 网络低延迟连不上系统辅助服务时显示中文提示，不再露出命令行英文；「Thermo 后台组件」统一叫系统辅助服务。
- 专注计时、内存、菜单栏提示等处的「名称：数值」冒号跟随界面语言。

## 1.5.14

- 搜索：用中文输入法时按快捷键打开搜索，会临时切到英文键盘，直接敲 xtsz、chrome 就能搜，不会先进拼音输入框；关掉搜索后恢复原来的输入法。不需要的话可以在搜索设置里关闭。
- 搜索：常用的应用排得更靠前，比如输入「设置」时，常开的「系统设置」会排在没打开过的「设置助理」前面；名字完全一致的结果仍然最先。
- 长截图和录屏选区域时也用新的选区：画面先定格，可以点选窗口，拖出区域后还能调整大小和位置。

## 1.5.13

- 标签整理：「暂存并关闭」的列表按网站名分组（GitHub、Zegocloud），本机开发页面合成「本机页面」，不再显示 127.0.0.1；「内存诊断」还没测内存时不再每行写「无对应读数」。
- 操作记录的类型筛选换成和「刷新」同款的小按钮菜单。
- 智能检查的英文问题描述句首大写，PID 统一写法，单个脱离进程不再写成 process(es)。

## 1.5.12

- 截图换成 Thermo 自己的选区：按下快捷键先定格整屏，鼠标停在窗口上就高亮它，点一下即选中；也可以拖出任意区域，再拖边角调整、拖动挪位，方向键逐点微调（Shift 一次 10 点，Option 改大小）。选区旁显示像素尺寸，选择时有放大镜显示坐标和颜色，按 C 复制颜色。回车按设置完成，⌘C 只复制，Esc 取消。
- 搜索：中文系统里「终端」「系统设置」「计算器」「访达」「活动监视器」等系统应用现在能用中文名和拼音首字母（如 xtsz、jsq）搜到，结果也显示中文名；Safari 重新出现在结果里。
- 概览和传感器显示机型名（如 MacBook Pro (14-inch, M5)），CPU/GPU 列表带应用图标；菜单栏面板的风扇单位跟随语言，可用空间写明总容量。
- 残留扫描遇到 macOS 保护的应用容器时说明需要完全磁盘访问权限；指向不存在位置的应用内链接不再误报。
- 磁盘清理、设置、菜单栏菜单与英文界面的若干文案和布局细节更清楚。

## 1.5.11

- 新增专注计时：专注、短休息、长休息，计时时菜单栏显示倒计时，可选显示进度图标。默认不会自动开始，从面板或菜单栏的「专注计时」手动开启。
- 休息时每块屏幕铺上各自的桌面壁纸，挡住其他窗口，切到全屏应用也照样覆盖；可以推迟 1 分钟、停止休息，或直接开始下一轮专注。
- 界面语言新增日本語（目前只翻译了专注计时，需要在设置里手动选择）。

## 1.5.10

- 标签整理：分组名跟着界面语言走（中文里飞书叫「飞书」、Google Docs 叫「Google 文档」），不认识的网站用网站名而不是完整域名；页面合成一张卡片，一行数字、一行分组，更清爽。
- Thermo 以前用网址命名的分组（如 portwind.jp.larksuite.com）可以一键改成网站名称，只改 Thermo 自己建的分组；需要 chrome-use 支持改名，旧版会提示先更新。

## 1.5.9

- AI Agent 诊断：MCP 配置里写着明文凭据（令牌、Authorization 请求头）时，问题旁边多了「在访达中显示配置」，直接打开对应的配置文件去改，并提示把密钥移到钥匙串或环境变量后更换。

## 1.5.8

- 传感器可以按温度从高到低排，一眼看到最热的地方。
- 启动项可以搜索；操作记录可以按类型筛选，自动整理标签的记录不再把其他操作淹没。
- 风扇已经是自动时「应用」不再可点（出错后仍可重新恢复自动）。
- 插件只有命令行工具待更新时写明「命令行工具可更新」，不再显示两个相同的版本号；应用商店里 Thermo 自己显示「正在使用」。
- 空间透视的「较小的项目」不再显示 0 B；没有残留数据时不显示「全选」。

## 1.5.7

- 云析下载不再在页面切换和后台刷新时反复弹出钥匙串授权；需要授权时显示明确入口，拒绝后不自动重试。读取失败时保护已有账号和下载记录。
- 完善程序列表的排序、进程操作和名称显示；应用列表显示上次打开时间，诊断建议可直接定位进程。
- 标签整理按网站合并，并说明没有可整理标签时的情况；磁盘扫描显示剩余空间，下载失败时可删除未完成部分并释放空间。
- 修复截图脚本在内存压缩和交换时的用量计算，统一截图菜单图标。

## 1.5.6

- 修复从终端等其他应用呼出搜索后，第一次点击「预览」等操作没有反应的问题。
- 修复预览接管焦点时窗口被提前关闭或清空的问题，关闭预览后可继续使用搜索。

## 1.5.5

- 操作记录：删除失败时不再写「已永久删除」；空间透视里手动永久删除的记录标题正确；标签数量写成「N 个标签页」，超时等状态显示中文。
- 菜单栏图标的右键菜单和截图菜单按「截取 / 钉图 / 管理 / 设置」分组，右键菜单可以直接打开「AI 体检」，「设置…」挪到操作记录旁边。
- AI 体检换用独立图标，侧栏里更好认。
- 继续打磨各页细节：内存统一用 GiB、风扇名称本地化、风扇曲线固定显示最近 10 分钟，清理页没选东西时不再显示「0 B」，底部操作栏不再透出后面的内容，一分钟内的时间显示「刚刚」。

## 1.5.4

- 搜索支持直接粘贴文件和文件夹路径，无需索引即可打开、在访达中定位或预览；图片和 PDF 可选择用苹果「预览」打开。
- Markdown 预览改为阅读窗口，支持标题目录、表格、任务列表、本地图片、文内查找和源码切换。

## 1.5.3

- 新增「AI 体检」（侧栏「概览」下面）：让本机的 AI（magpie、Ollama、LM Studio 或 Claude Code）看一遍 Thermo 测到的整台 Mac——内存和 swap、CPU 负载、温度和风扇、电池、磁盘，以及概览里标出的那些程序（codex app-server、闲置的 MCP 副本、AI 会话），给出先做什么。
- 每一条都写明做了会不会影响手上的工作：「放心做」「会打断工作」「别动」，并说清楚会中断哪些会话、什么时候做更好。不知道结束某个进程会不会出事时，先来这里看一眼。
- 它只给建议，不会结束、清理或改动任何东西；每条有按钮跳到对应页面（概览、内存、风扇、空间透视）去处理。第一次会先给你看要发送的内容（读数、程序名和项目文件夹，不含文件内容），单独征得同意。

## 1.5.2

- 「空间透视」打开任意文件夹后，路径栏右边多了「AI 整理」：把这个文件夹里最大的 40 项（名字、大小、文件数、修改时间，不含文件内容）一次发给本机的 AI，逐项给出「可以删 / 先确认 / 保留」、理由和更好的命令（如 `cargo clean`）。
- AI 说可以删、Thermo 也允许的项会先勾好，你可以改；点「勾选」只是加入待删清单，还要在「检查…」里确认才会删。上锁的项照旧不能勾。

## 1.5.1

- 「空间透视」确认删除时可以勾「直接删除，不放进废纸篓」：立即释放空间，不能撤销，删除记录写在 `~/Library/Logs/Thermo/clean.log`。不勾时仍和以前一样移到废纸篓。
- 项目里的 `.git` 不再上锁，可以勾选；确认页会写明这个仓库的历史、分支、stash 和没推送的提交会一起没掉。密钥凭据、iCloud、邮件、系统文件夹和白名单里的路径照旧锁着。

## 1.5.0

- 拿不准能不能删时可以「问 AI」：清理里「需要确认」的项目、「空间去向」详情、「空间透视」右键菜单都有这个入口。它问的是这台 Mac 上已有的 AI，依次找 magpie、Ollama、LM Studio，最后用 Claude Code；默认挑最快的小模型（如 Haiku），几秒内给出「可以删 / 先确认 / 保留」、理由和更好的做法（比如 `xcrun simctl delete unavailable`）。
- 只发路径（`~` 开头）、大小、修改时间、Thermo 的说明和里面的名字，不发文件内容；第一次会先给你看要发的内容。AI 只给建议，不会替你勾选或删除，Thermo 原有的保护照旧生效。找不到本地 AI 时不显示这个入口。

## 1.4.9

- 「空间透视」改为测量整个磁盘：顶层从 Macintosh HD 开始，个人文件夹、应用程序、系统、private、opt 都在里面；交换文件、启动文件、恢复系统等单独宗卷和系统保护无法读取的部分各占一行，合计等于磁盘已用空间，不再只看到个人文件夹那 600 多 GB。
- 路径栏多了「个人文件夹」按钮，一键回到 `~`。移到废纸篓仍只允许个人文件夹里的内容。

## 1.4.8

- 「空间去向」重做：顶部一条按分类着色的容量条和图例；分成「你的数据」和「macOS 管理」两组，每行是彩色图标、名称、大小，可清理的标出「可以清理」。
- 点任意一行打开详情：这是什么、可以怎么做（直接去清理或复制命令）、里面最大的文件夹，可在访达中显示。macOS 说不清的「系统数据」在这里拆成了项目、工具与 agent 目录、模拟器、交换文件等具体去处。

## 1.4.7

- 项目构建产物不再因为开着 Codex、Claude 等 agent 就整块锁死：可以勾选清理，行内提示删除后可能要重新构建。正在运行的构建工具、可执行文件仍会挡住删除。
- 「大文件夹」不是构建产物，只能逐个勾选，「全选」不会再带上它们。
- 不再把 `~/.codex`、`~/.claude`、`~/.wx-rs` 这类工具自己的隐藏目录列成「大文件夹」，避免误删 agent 的数据。

## 1.4.6

- 扫描明显变快：项目扫描不再逐个等待 `git ls-files`。
- 界面更省电：语言查询不再每个字符串都读系统设置，下载进度每秒最多刷新 4 次，后台诊断不再重复打开会话文件。
- 500 MB 以上的构建目录在默认扫描里也显示删除后预计释放的大小；与克隆或快照共享的部分会写明，JSON 新增 `allocatedBytes`。
- `thermo clean run` 实际释放远少于预计时明确提示，JSON 新增 `spaceShortfall`。
- `thermo clean overview` 被预算中止时也报告未归类的已用空间，并写明可回收和无法读取的部分。
- 用 `CACHEDIR.TAG` 识别 `CARGO_TARGET_DIR` 这类自定义名称的构建目录。

## 1.4.5

- 磁盘清理不用等扫描结束：已找到的项目可以边扫边清理，每一行也能单独清理；空间透视重新测量时同样可以移到废纸篓。
- `thermo clean` 被取消时报告 `stopReason`（budget、user、signal）、`budgetSeconds`、`unfinishedSteps` 和 `unfinishedCategories`，错误信息写明原因。
- `thermo clean overview` 默认预算改为 120 秒，可用 `--budget` 加长；到期返回下限并以退出码 3 结束。
- 项目目录里超过 5 GB 的非构建文件夹（快照、备份等）作为「需要你决定」的条目列出，不会自动选中。

## 1.4.4

- 修复重试分享下载时报「转存文件 token 校验异常」：重新打开分享后会刷新文件 token。

## 1.4.3

- 修复云析下载重启后把失败或从未开始的任务都显示为「已暂停 0 B」：现在保留失败原因，未开始的任务单独标注。
- 失败的任务可直接重试；重启后的已下载量按磁盘上的实际数据显示。
- 移除不再使用的迅雷密码登录代码。

## 1.4.2

- 重做云析下载页和复制链接提示；账号与设置移到右上角。
- 登录改为在 Chrome 中完成，Thermo 自动读取并校验，需要安装 chrome-use（应用内一键安装）；123、光鸭、蓝奏优享、蓝奏云仍用密码或短信。
- 修复先打开分享、后登录账号时，下载仍按游客处理的问题。
- 新增「插件」菜单管理 leeguooooo 插件；软件管理新增「应用商店」标签。

## Unreleased

- 云析下载页重做：单列粘贴框、固定列的文件与下载列表、悬停操作、面包屑、可折叠文件夹；账号和设置收进右上角；剪贴板提示改为通知样式。
- 修复打开分享后才添加账号时仍走游客取链、夸克大文件报「超出游客大小上限」的问题，所有网盘改为下载时读取当前账号。
- 云析下载的网页登录改走用户自己的 Chrome，移除内嵌网页登录窗口；只有没接网页登录的平台保留账号密码或短信。
- **云析下载现在依赖 [chrome-use](https://github.com/leeguooooo/chrome-use)**：页面提供一键安装（仅在点击后运行官方安装脚本）。监控等其他功能不需要它。

## 1.4.1

- 复制网盘、视频或磁力链接时弹出提示，点「打开」直接进入云析下载（可在下载设置中关闭）。
- 添加账号时优先从 Chrome 导入已有登录，失败才打开登录窗口；移除手动粘贴 Cookie，登录窗口不再裁切页面。以上均未经真实账号验证。

## 1.4.0

- 新增「云析下载」页（实验性，**未经真实账号验证**）：9 个网盘（夸克、UC、迅雷、139、123、115、光鸭、蓝奏、蓝奏优享）、7 个视频平台、磁力/BT（Gopeed，首次使用时下载）、HLS 与 DASH 合并（FFmpeg，首次使用时下载）、多账号（凭据只存钥匙串）与加密备份。
- 移植自 YunX，第三方声明见应用内 THIRD_PARTY_LICENSES。

## 1.3.5

- 新增「Claude 工具」入口，账号、重置、隐私与网络收进一个子菜单。
- 新增 Claude 账号页：管理自己的多个账号，每个账号有独立的登录和历史，可在终端打开或拷贝启动命令；新增 `thermo agents claude-profiles`。Thermo 不读取登录凭据，也不改动地区或设备信息。
- 修改临时目录归组代码，绕开 1.3.4 磁盘扫描时在 macOS 15 上的一处崩溃。
- 修复退出时误报「贴图库已损坏或无法读取」并拦下退出的问题：没有打开贴图时不再写贴图库，只有贴图改动未保存才会阻止退出。

## 1.3.4

- 重新排版「为什么卡」卡片：先一句状态和总共能释放多少内存，每个原因一行（名称、可释放量、操作按钮）加一句建议，证据和会话列表收进「详情」；样式与概览页其他部分一致。
- 修复卡片标题在「16.7 GB」这类小数处被截断。

## 1.3.3

- 新增「为什么卡」：概览和菜单栏直接列出拖慢 Mac 的 1–3 个真凶，写明原因、由哪个会话或程序启动、处理后约能释放多少内存，以及该怎么处理。命令行可用 `thermo pulse why`。
- 按 Activity Monitor 的「内存」口径（含压缩和换出的部分）排序，不再被 RSS 误导；能识别持续高 CPU 的进程、父进程已退出却还在空转的孤儿进程、占着几 GB 内存却不干活的卡死工具，以及每隔几秒反复拉起子进程的后台程序。
- AI 会话专项：找出 codex app-server 堆积的上百个 MCP 子进程，以及同一个 MCP 服务在每个会话里各开一份的情况；按会话是否还在用区分，只建议结束已结束或闲置会话的副本，正在用的项目保留。新增 `thermo agents sessions` 查看每个会话挂了哪些 MCP 服务。
- 一键结束：先确认并复核进程身份，请求退出后不响应再强制结束，记入操作记录，并报告结束后 swap 和负载的变化。系统进程、AI 会话、App 和正在使用的会话里的工具不提供一键结束。命令行为 `thermo pulse end PID`。
- 主动提醒：swap 快用完（即使已经不再增长）、进程持续失控、卡死占内存、子进程堆积时发通知，同一原因每小时最多一次。
- `thermo memory` 先给出结论和处理建议，再列表格。
- 磁盘清理：/tmp 和临时目录里工具留下的文件夹按工具归组，显示数量和闲置时长；其中的 git worktree 通过 Git 移除，有未提交改动的保留；正在使用的跳过。Chrome 等应用的代码签名副本按实际打开情况保留在用的那份。

## 1.3.2

- 修复 Finder 等位于 CoreServices 的系统应用搜不到的问题。
- 应用索引支持多层分组目录，修复应用放在较深文件夹时漏搜的问题；仍跳过应用包内部和目录软链接，避免重复扫描与循环。
- 菜单栏管理仍为实验功能，默认关闭；已知 macOS 27 图标隐藏与多屏兼容限制仍适用。

## 1.3.1

- 测试版：菜单栏管理仍为实验功能，新用户默认关闭；现有用户保留已保存的开关和分组。
- 可将应用拖入显示、隐藏、始终隐藏分组，分组在重启后保留；支持可选的自动收起和展开／恢复快捷键。
- 已知限制：macOS 27 的隐藏接口可能连带隐藏显示组应用和专注模式等图标。图标缺失时点“恢复全部图标”；必要时正常重启 Thermo。主屏刘海、多屏切换、物理睡眠唤醒与真实权限撤销仍有验收缺口，不建议依赖此功能处理重要工作。
- 修复辅助功能权限撤销后菜单栏快捷键未释放的问题；恢复失败时保留恢复快捷键。
- 包含 1.3.0 后的多屏录屏选区校验与显示器变化处理，菜单栏折叠原型仅用于测试，不作为应用后端。
- 本测试版仅通过 GitHub Releases 手动下载安装，不进入稳定更新源，包内自动更新关闭；后续版本需手动安装。

## 1.3.0

- 新增区域与窗口截图、剪贴板贴图、图像标注和本地 OCR；默认使用 ⌥⌘3 截图、⌥⌘4 贴出剪贴板，也可从菜单进入。
- 贴图支持分组和关闭历史、锁定、临时鼠标穿透及独立恢复、旋转翻转、裁剪微调、颜色调整、像素取色，以及后台批量保存。
- 常用标注支持多选、移动缩放、箭头端点和评论编辑、折线逐点调整、序号样式与撤销重做；图像可按完整分辨率或显示尺寸复制保存。
- 菜单栏管理提供可选的自动收起、展开与恢复快捷键；权限撤销后释放快捷键。菜单栏管理仍为实验功能，默认关闭。
- 长截图当前采用手动滚动与重叠匹配，最多 8000 万像素；录屏及摄像头、麦克风和键盘图层的真实设备兼容尚未完成验收，相关输入默认关闭。
- 截图的多屏、Retina、Space 选窗和权限变化，以及取色的物理画布操作仍有实测缺口。翻译暂缓，不宣称完整兼容 PixPin。

## 1.2.5

- 主窗口被遮挡、最小化或关闭后，CPU、GPU、内存与连接页面停止实时采样；恢复可见时重新读取，关闭后释放页面内容。
- CPU 页面不再额外读取 GPU 数据，主窗口按页面选择传感器采样范围，保留侧栏和菜单栏所需指标。
- 菜单面板的 GPU、磁盘与内存读取移到后台，关闭或重开时丢弃过期结果。
- 减少整页刷新，移除实时仪表和内存条随采样反复播放的动画。

## 1.2.4

- 修复菜单栏浮窗偶尔向左偏移、压住菜单栏、底部被截断的问题：浮窗按图标所在的屏幕定高度，打开后不再随内容变化改变大小；接外接显示器时也能正确显示。

## 1.2.3

- 搜索可以用 ⌘Space 打开：搜索面板顶部和搜索设置里点「使用 ⌘Space」，Thermo 关掉聚焦搜索的 ⌘Space 并接管；随时可在设置里还给聚焦搜索，改用其他快捷键时也会自动还原。接管和还原都记入操作记录。
- ⌘Space 被 Raycast 占用时会提前提示，并可直接打开 Raycast 去改快捷键。
- 修复搜索框上方的大块空白。
- 新增 `thermo search use-command-space` / `give-back-command-space`。

## 1.2.2

- 修复菜单浮窗在采样完成且没有异常原因时仍显示「检查中…」的问题，说明区继续保留固定高度。

## 1.2.1

- 修复部分 M5 机型使用小写 `F0md` 模式键时无法切换最大转速、恢复自动或核对状态的问题；重新发现硬件键，继续检查每次写入结果。
- 菜单浮窗正文固定高度并滚动显示，采样和错误提示不再改变窗口大小；顶部说明预留两行，避免按钮随文字换行上下移动。
- 未知风扇状态不再默认选中「自动」；多风扇快捷按钮一次提交全部风扇，缺少回读键时显示中文说明并保留原始错误详情。

- 修复菜单栏「清洁屏幕」「网络低延迟」「保持唤醒」「电池充电保护」设置弹窗显示全白的问题：工具入口统一由主窗口承载，并在呈现前关闭菜单浮窗。
- 清屏快捷键说明完整换行显示，避免退出方式被截断。

## 1.2.0

- 新增应用和本地文件名搜索：Option+Space 打开，支持中文、拼音、缩写、轻微拼写错误、收藏与别名。文件目录由用户添加，名称索引只保存在本机，不读取文件内容。
- 搜索支持键盘选择、回车打开、Finder 显示、Quick Look 与复制路径；可设置快捷键、排除规则、隐藏文件和使用历史。
- 新增 `thermo search query/status/index/open/settings`，可独立检索本地索引；覆盖不完整或匹配候选达到上限时明确报告。
- AI 检查新增 Claude 本机只读诊断与脱敏报告。

## 1.1.42

- 全部页面视觉重做：统一的字号与间距，每页只有一个主角数字（概览以温度和热量色阶为主）；长说明收进标题旁的 (?)，安全提示仍直接显示。
- 所有可勾选列表统一加「全选」：每组标题上的三态全选，底部栏显示已选数量（Claude 清理、残留文件、磁盘清理分类、空间透视大文件与重复文件、标签整理、MCP 批量检查）。
- 风扇页检测中不再显示假的「0 转/分」；设置页按系统设置的样式分组；菜单面板固定深色。
- 菜单栏图标右键默认弹出原生菜单：直达各页面，保持常亮（30 分钟 / 1 小时 / 2 小时 / 直到关闭）、清洁屏幕、低延迟、充电保护，以及检查更新、关于和退出。
- 新增「连接」页：Wi-Fi 信号、噪声、速率、信道与标准，扫描附近网络；蓝牙已配对设备一键连接/断开，AirPods 显示左耳、右耳和充电盒电量；声音输出切换、音量与静音。网络名称需在系统中允许定位服务。
- 电池详情显示电源适配器功率。

## 1.1.41

- 空间页扫描大幅提速：整个个人目录从几十分钟缩短到约一分钟；各顶层目录轮流扫描，中途停止也不会漏掉大目录；没扫到的目录显示「未测量」，不再当成 0 排到最后。
- AI 检查新增「Worktree」：发现遗留 worktree 过多的项目，文件夹已不存在的记录可一键 `git worktree prune`（不删文件）。磁盘清理现在也能找到仓库外的 worktree（如 `~/.codex/artifacts`），有未保存改动、在用或最近改过的一律保留。
- AI 检查发现过大的数据库预写日志（codegraph、Codex），并提示仍在运行旧版 codegraph 的后台进程；一键升级 codegraph 并正常重启旧进程，不删除 -wal 文件。
- 插件和 Skill 可以检查更新、一键更新：Claude Code 插件按本地市场目录比较版本，Skill 用 `thermo agents updates --check` 到 GitHub 核对；更新和卸载都调用各工具自己的命令。长期没用或装了从没用过的 Skill、插件会提示；Codex 插件也列出并可卸载。
- 新命令：`thermo agents updates [--check]`、`thermo agents update [名称]`。

- 应用菜单与 ⌘⇧P 可直接打开菜单小面板，即使左右键都设为主控制台；正文按屏幕高度滚动，底部操作说明、设置与快捷工具固定显示。进入控制台时显式关闭小面板，隐藏面板不再保留采样；当前读数与历史曲线分开，等待新样本时显示未知。

- 风扇数量读取失败或非法时保留未知状态并重试，只有确认零风扇才显示无风扇；发现缓存升级为 v3 并校验记录完整性，未知结果不写入缓存。风扇控制拒绝使用未知发现结果。CLI 和流式 CSV 保留风扇可用性，恢复后保持列布局一致。

- 风扇状态区分尚未采样与实际空结果，后台只读温度时不会在面板、概览或风扇页误报“无风扇”。
- 内存页先显示当前读数，再补历史曲线；重开时等待旧读取结束并丢弃旧结果，增长分析共用同一份已排序时间线。
- CPU 页重开会在旧读取结束后立即刷新，关闭时取消尚未开始的读取及进程遍历；内存页关闭后不再接受延迟刷新，当前可见页面的采样使用交互优先级。

- 新增普通保持唤醒：屏幕、任务或组合模式，支持限时和手动结束；低电量暂停，接电后恢复。面板关闭后继续，退出 Thermo 后结束。
- 菜单栏支持独立主次指标、单项或双项、图标和数值组合、横向或双行显示，以及左右键分别打开面板或主窗口；新增 CPU 使用率、内存和上传下载速度。保留旧设置与 CLI 用法，缺失或过期读数显示未知。
- 项目构建产物扫描覆盖主目录下的普通一级目录，排除系统目录、媒体库、同步盘和其他挂载卷；补充 Swift 项目的 `dist` / `build` 及影片项目的 `out`。
- 按内容识别构建缓存时校验 `CACHEDIR.TAG` 的标准签名，拒绝同名目录、管道和软链接；执行不可恢复清理前再次核对扫描时的缓存依据，依据改变时要求重新扫描。

## 1.1.38

- 磁盘空间提前提醒：剩 30 GB、15 GB 时各提醒一次（之后每 12 小时提醒一次），剩 5 GB 时每小时提醒；按最近 15 分钟的写入速度，3 小时内会写满时也会提醒。swap 占用较多时，提醒里会说明它占了多少硬盘。可在设置里和其他提醒一起关闭。
- 清理项目构建产物时，`node_modules`、`.build`、`target` 等可重新构建的目录改为直接删除，不再移进废纸篓。以前移进废纸篓后空间并没有释放。`dist`、`build`、`out`、`coverage` 可能存有需要保留的文件，仍然移进废纸篓，可以恢复。
- `thermo clean run` 支持把多个 ID 写在同一个带引号的参数里（按空格拆开）；有 ID 没匹配上时，报错会列出是哪几个。
- AI 诊断：按外层工具拆分返回用量，区分调用累计耗时和观察占用时间，单独统计 Skill 指令正文的加载量，可显式分析单个会话的日志；MCP 错误按工具自报的错误码细分，并检查失效的本地 schema 引用和 Skill 目录引用。
- 辅助程序：升级时保留用密码安装的服务注册，等旧进程退出后再加载，安装中途失败不会再误报成功；风扇恢复自动模式时会等读回确认。
- 独立窗口关闭统一经过完整的退出保护；废纸篓恢复能识别原项目已经放回；标签加入已有分组却落进新组时会报告失败。

## 1.1.28

- 新增清洁屏幕：限时黑色遮罩、输入拦截、退出与恢复保护；可选全局快捷键默认关闭，支持录制、冲突检查和移除。
- 进程说明增加当前父子关系、工作目录附近的 Git 信息、TCP 监听和电源请求；结果注明读取范围和缺失信息，不把当前祖先当成原始启动者。
- AI 会话默认全部保留。清理旧会话需要明确选择保留期限，执行前再检查运行状态、保护范围及扫描后的变化。
- 开发缓存原生命令绑定扫描时的目录、程序和执行范围；确认后工具或白名单变化会停止工具操作。修正工具删除整个目录后的空间计量和部分失败记录。
- 风扇读数与控制状态不可用时显示未知，区分请求策略与硬件复查；缺少有效转速范围时禁用最高转速设置。
- 新增限时 AWDL 网络控制入口和 `thermo awdl` 命令，需更新辅助程序。使用期间 AirDrop 等点对点功能可能不可用；状态、停止和恢复结果单独显示，不承诺延迟收益。
- MCP 配置可明确勾选后按顺序批量检查，支持停止和总时限；仅启动所选配置服务并读取定义，不调用业务工具，也不将结果当作宿主实际加载配置的证明。

## 1.1.27

- 标签智能分组不再重复建组：同一网站在同一窗口已有 Thermo 建的分组时，新标签加入该分组（单个新标签也会加入），不再每分钟新建一个同名分组。需要 chrome-use 扩展支持（随下一版 chrome-use 发布）；扩展还不支持时，自动分组会跳过这些标签，不再重复建组，界面会提示更新。
- 只加入 Thermo 自己建的分组：通过分组记录确认，不按标题匹配。chrome-use 的 agent 分组，以及你自己建的分组，即使同名也不会被改动。已在分组里的标签保持原样。
- `thermo tabs organize --dry-run` 会标出哪些分组是「加入已有分组」，确认提示也会分别列出新建和加入的数量。

## 1.1.26

- `thermo pulse` 每一行都把同一程序在同一文件夹的所有进程算进来，不再只合计其中较大的几个；同一程序在其他文件夹还有副本时，会标出「另有 N 个进程在其他 M 个文件夹」。JSON 新增 `processCount`、`elsewhere`、每个进程的 `ppid`/`owner`/`project`，以及 `sampled`、`units`（各数值的单位和内存口径）和 `selection`（列出哪些程序、每行统计范围）。同一行的进程由不同 agent 启动时，不再只写第一个，而是全部列出（`owners`）。
- 新增 `thermo pulse inspect NAME|PID`：一个程序在所有文件夹的全部副本，逐个进程列出内存占用（footprint）和 RSS、CPU、运行时长、父进程和启动者，并标出启动者已退出的进程。只能作为判断是否遗留的线索，不能直接证明泄漏。
- `thermo pulse history` 记录每行的进程数和内存口径（`peakProcesses`、`memoryMetric`），JSON 附带单位说明。
- `thermo agents` 的进程列表注明内存是驻留内存（RSS），JSON 增加 `memoryMetric`。
- 内存页把口径说明移到程序列表上方：内存占用即活动监视器的「内存」列，含压缩内存（可能部分已换出），各程序相加不等于已用内存，也不等于 swap。
- 不在 Thermo.app 里的 `thermo` 副本（例如复制到 `~/.local/bin` 的）比已安装的 App 旧时，会提示版本差异，并给出改成指向 App 自带命令的方法；不会自动改动该文件。

## 1.1.25

- 菜单栏面板重新设计：CPU、GPU、内存、可用空间、网络、风扇改成卡片，有最近两分钟的曲线和温度标记；电池显示放电功率和剩余时间；「占用最多的程序」标出所在项目和启动它的 agent；顶部一句话说明现在是否过热或超负荷、主要原因是什么。
- 清理开发缓存时优先用工具自己的命令：npm、Yarn 1、pip、uv、Go 构建缓存分别执行各自的清理命令（如 `npm cache clean --force`）。找不到工具、被白名单保护或选择移到废纸篓时，按原方式处理；命令失败时保留文件夹，不在出错的工具背后删除。确认前会列出将要执行的命令。
- 支持用 Homebrew 安装：`brew install --cask leeguooooo/tap/thermo`，App 和 `thermo` 命令行一起装。
- 新增启动项管理与 Homebrew 应用更新，卸载前复核应用文件。

## 1.1.24

- 「合盖不休眠」新增「过热时自动关闭」选项（默认开启，可在菜单栏取消勾选；命令行用 `thermo awake on --no-heat-guard`）。关闭后只在使用电池且电量降到 20% 时自动关闭；macOS 仍会在温度过高时自动降频，到危险温度会强制关机，风扇超温保护也保持开启。辅助程序会自动更新。

## 1.1.23

- 修正「合盖不休眠」在部分 Apple Silicon Mac（如 M3）上按 Intel 标准在 85 °C 就自动关闭的问题，改为按实际 CPU 判断，Apple Silicon 为 100 °C。

## 1.1.22

- 菜单栏新增「合盖不休眠」开关（笔记本，经 Thermo 辅助程序；也可用 `thermo awake on|off|status`）。以下情况会自动关闭并发通知：温度比风扇安全上限低 10 °C（Apple Silicon 100 °C，Intel 85 °C）时；使用电池且电量降到 20% 时；连续读不到温度时。关闭、辅助程序重启或更新时，都会恢复你原来的睡眠设置，不会一直保持开启。首次使用需要更新辅助程序。
- 概览新增「最近 15 分钟」时间线：温度和每核负载上下对齐，标出哪个程序开始或停止大量占用 CPU（带项目和 agent），以及 Thermo 做过的操作。
- 传感器页、风扇页改用和概览、操作记录一致的面板样式；风扇的转速范围和模式直接显示在名称下面。
- 卸载由管理员账户安装的应用时，会先说明 Thermo 无法移动它、请在访达中拖到废纸篓，不再中途失败。（1.1.21 说「可以放回 root 拥有的应用」并不准确：macOS 不允许 Thermo 移动这类应用，所以它们不会进入可恢复的批次。）

## 1.1.21

- 概览改为「热链路」：顶部一句话说明为什么热、为什么慢，同一项目里由同一个 agent 启动的程序合并点名；中间按负载 → 温度 → 风扇 → 系统热压力排列，标出出问题的一环，风扇的自动/最大就在风扇这一环上；其他资源收成一行。
- 新增「操作记录」页和 `thermo history`：清理、卸载、agent 修复、Claude 重置、隐私设置、标签整理、归档和退出程序都记在同一个日志里，每条写明在哪里撤销；大小未测量时不写成 0。
- 卸载应用、移除残留和空间透视的移到废纸篓都会记成批次，可在操作记录页或用 `thermo clean restore BATCH` 放回原处；原位置已有新数据、废纸篓里的项目被改动或换过时会跳过，不会覆盖。
- 新增持久清理白名单（`thermo clean whitelist`，或在智能扫描里选「始终保留」）：所有清理、卸载和移到废纸篓都会跳过白名单里的路径；白名单文件不可信或读不出时拒绝清理。

## 1.1.20

- 重新设计“Claude 清理”页：摘要显示本地数据、可重置和锁定数量，锁定原因及解除方法只说明一次；按 Claude Code、桌面端、Claude-3p 分组，每行一句影响，展开查看完整说明、路径和锁定原因。
- 底部操作栏显示已选项目和大小，并说明数据移到私有恢复目录、不会释放空间；确认窗口逐项列出完整影响和路径，仍需输入 RESET。
- 恢复记录显示项目数、大小以及部分或全部已恢复状态，全部恢复后不能再次恢复；无法测量的大小显示为未知，总量显示为下限。
- 隐私与网络页改为逐行操作，标注需先退出浏览器、需管理员授权、无法撤销、会发送公网 IP 等前提，执行前仍显示完整说明。

## 1.1.19

- 新增独立“Claude 清理”页：逐项重置 Claude Code 与桌面端本地状态，执行前确认，保留私有恢复副本，保护运行中的会话及新生成的数据。
- 新增隐私与网络工具：浏览器定位/WebRTC 设置及恢复、mail.com Cookie 定向清理、Claude 用户 launchd 变量清理、DNS 缓存刷新和时区查询/切换。浏览器修改要求完全退出，Cookie 备份附来源清单，系统操作单独授权。

## 1.1.18

- 新增 CPU、GPU 占用页面：整机使用率、最长 15 分钟的实时曲线、按程序汇总的占用列表；可搜索程序、项目或 PID，展开查看各进程。
- 程序 CPU 通过两次采样计算，100% 对应一个逻辑核心；GPU 时间占比来自驱动可读取的客户端，缺失计数器明确显示未知，新进程和计数器重置重新建立基线。
- 页面打开时每 2 秒采样，离开后停止。新增只读命令 `thermo activity --json`，与界面共用采样器。

## 1.1.17

- 标签整理拆成“整理 Chrome 标签”“暂存并关闭”“已暂存”三个明确入口；默认展示 Chrome 分组预览，自动整理与自定义规则收进进阶设置。
- 暂存操作说明保存网址后关闭页面，确认前列出实际操作范围；当前、固定、音频等受保护页面明确显示保留，切换窗口会清除选择。
- 已暂存页面提供重新打开入口与空状态引导；窗口选择显示当前页面标题，本地分类说明与 Chrome 原生分组的区别。

## 1.1.16

- 清理扫描在 JSON 模式下也持续显示 stderr 进度，默认采用 60 秒协作式预算；支持 `--timeout`，大型项目和工作树有界测量并明确标记估算、下限，`--exact` 可完整测量。
- 工作树清理重新检查内容、进程和锁持有者，只通过 Git 处理选中注册项；文件与恢复所需注册副本保留在废纸篓，分支保留。新增 `clean repair-worktrees`，审阅后可备份并修复指定仓库已有的悬空 agent 注册。
- 递归删除中途失败时计入可确认的已删除估算，报告部分完成和剩余错误，无法完整计量时明确标记未知；日志和 JSON 同步记录结果。
- 废纸篓清理返回批次编号，新增 `clean empty-trash BATCH --dry-run` 和 `--yes`，只处理本批记录的项目；已恢复、替换、身份变化或仍被使用的内容保留。
- 清理报告增加 swap、模拟器 runtime 镜像和可清除空间信息，区分目录占用与共享容器数据；保存扫描快照，完整同范围、同口径的结果显示前后大小变化。
- 识别没有 Cargo.toml 的 Rust 缓存 target，保留开发依赖与活跃构建保护；Claude scratchpads 改为审阅，并提示大媒体文件，避免误删渲染成果。

## 1.1.15

- 内存页按程序汇总同名进程，展开后查看各项目与完整进程列表；支持按程序、项目或 PID 搜索，数值和操作按钮对齐，窄窗口使用分行布局。
- 分开显示内存占用与驻留内存，修正两种口径混用和读取失败时显示为零的问题；不再根据两者差值断言程序已被压缩或换出。
- 新增程序占用曲线和当前 swap 读写速率；持续增长提示校验进程身份，不把重启、成员变化或仅仅运行时间长当作泄漏证据。
- 汇总展示保留各项目的结束范围及受保护进程规则，不会一次结束所有同名程序。
- 新增只读命令 `thermo memory --json`，与内存页共用采样和归组结果。
- 标签整理预览显示标签总数。

## 1.1.14

- 支持自动整理 Chrome 原生标签组：按网站或自定义域名规则生成预览，确认后执行，可撤销；已有标签组和受保护页面保持原样，不跨窗口或账号移动。
- 增加可选的持续自动整理：Thermo 运行期间每分钟处理新出现的符合条件标签，默认关闭，不会关闭任何页面。
- 标签整理支持同时读取多个 Chrome Profile，按标签所属账号重查保护状态，不切换其他 agent 的浏览器连接。

- 增加标签组管理：按网站归类、自定义分组、保存后批量关闭、按组恢复；App 与 thermo-use 共用记录。
- 批量关闭保留当前、固定、音频、隐私及 agent 标签；保存记录校验、逐页重查、操作日志和跨进程互斥防止误关与重复恢复。
- 支持 `thermo tabs`，默认操作前方窗口，可指定分组、标签或窗口，恢复时可明确选择目标窗口。
- 默认清理保留开发依赖、SDK、模拟器数据、编译缓存、AI 模型和工作树，避免清理后立刻重建或下载。具体项目仍可手动选择。
- 新增 `thermo space archive PATH --to nas:/archive/name.tar`：通过 SSH 流式归档，保留稀疏文件、链接和元数据；接收端落盘、校验 SHA-256 与归档格式后保存恢复记录。默认保留本机原件，`--remove-local` 仅在源目录未变且未被占用时移除原件。
- 修正 APFS 签名副本的说明，区分含共享块的目录占用、独占块估算和清理后的实际可用空间变化。

## 1.1.13

- Where the space is accounts for the whole disk: every folder in your home, Library and the system data volume falls under a heading (apps, app data, projects, tool and agent folders, Apple's downloaded models and voices by name, system-wide data), macOS's own volumes are shown as what cannot be removed, swap and the sleep image come from the VM volume, and each heading says what to do about it. What cannot be attributed (APFS metadata, local snapshots) is one named line, and hard links or clones counted twice are said instead of hidden.
- A nearly full disk is named as the reason the Mac is slow (swap cannot grow, every write waits) instead of the busiest program; a warning appears below 5 GB.
- Leftover code-sign clones of apps (Chrome left one per relaunch): free while they share blocks with the app, a full copy each once it updates; the one a running app uses stays.
- The full cleanup scan takes about 35 s instead of minutes: APFS is asked for a file's reclaimable size only when the file may be a clone. Removing a chosen item no longer scans everything first, and 1,600 agent sessions go to the Trash in seconds instead of minutes.
- Cleanup categories show what is held back by a running app next to what can go now. The `claude` command line and Claude.app's browser helper no longer count as the Claude app running, which kept its caches from ever being cleaned.
- Memory gets its own section: where the memory is (apps, wired, compressed, cached files, free), swap on the disk, memory and swap over the last hour, six or 24, and every program by memory with its helpers and pages folded in, each with Quit, Restart or (for a browser) its pages.
- Worth a restart: programs that keep growing and do not come down, and big apps that have run for a day or more (Xcode, 26 h, 2.4 GB). Thermo records each program's memory every five minutes to tell a leak from a program that is simply big.
- When the disk is nearly full the Memory page says so first: swap cannot grow, which is what makes macOS say it has run out of application memory and ask you to force quit apps.
- Space Lens (Disk Cleanup): your home folder measured once, then any folder opens at once, biggest first, with a block chart beside the list; click a block or a row to look inside. Tick files or folders from any tab into one basket; they go to the Trash after a confirmation that lists every path. macOS and tool folders, keys, iCloud, mail, photo library insides and git metadata cannot be picked, and anything a program has open is skipped.
- Large files: everything of 100 MB or more, with when it was last opened, filtered to files not opened for 3 months or a year.
- Duplicates: identical files of 1 MB or more in Desktop, Documents, Downloads, Movies, Music and Pictures, compared byte for byte; keep the oldest of each in one click.
- `thermo space [PATH]`, `thermo space large`, `thermo space dupes` and `thermo space trash` do the same in the terminal.

## 1.1.12

- Uninstalling an app or removing leftovers updates the list in place instead of measuring every app (or searching for leftovers) again.

## 1.1.11

- AI Agent Diagnostics finds programs an agent started that keep crashing (each crash leaves a report and can show the "quit unexpectedly" dialog), with the crash reason and the newest report; it names the MCP server or hook that runs the program when only one does, otherwise the ones it could be.

## 1.1.10

- Uninstall apps (Disk Cleanup → Uninstall apps, or `thermo apps`): the app and the files it keeps in your home folder go to the Trash after you see every path; running, system and protected apps (password managers, VPNs, input methods, security software) are refused. Data left by apps you already deleted is found too (`thermo apps leftovers`).

- Cleanup checks each path again just before removing it: a path swapped for another file since the scan, or one a running program holds open (files or working directory), is skipped and named. Ages count when a file was moved or unpacked, not only its modification date.
- New cleanup items: Chrome, Edge, Brave, Arc and Chromium GPU and script caches in every profile; caches of Electron apps that are not running; editors' replaced extensions (VS Code, Cursor, Windsurf); Corepack, Electron, TypeScript, Carthage and Android caches; unfinished downloads and `.ipsw` firmware in Downloads.
- Homebrew's old versions (`brew cleanup`) and Go's module cache (`go clean -modcache`) are cleaned by the tools themselves, sized by Homebrew's own dry run.
- `pnpm store prune` removes packages no project uses; the result reports the space it actually freed. Chrome, Edge and Brave's previous version, left inside the app after an update until a restart, can be moved to the Trash while the browser is closed; the version in use and the app's signature stay intact.
- Uninstalling a browser, chat or mail app keeps its profiles, chat history and mail unless asked for (`thermo apps uninstall NAME --with-data`); the confirmation lists what stays.
- iOS device support keeps the two most recently used versions. A folder another rule covers (such as an app's logs inside ~/Library/Logs) is counted once.

## 1.1.9

- Disk scans show results as folders finish, support stopping and time budgets, and keep incomplete measurements clearly labeled. Scanning uses bounded concurrency and less memory.
- Space Overview lists projects and source folders separately, with shortcuts to scan build output, Xcode files, developer caches and temporary leftovers.
- Project cleanup recognizes build directories such as `target`, `.build`, `dist` and `node_modules`, preserves Git-tracked files and checks running agents, build tools and executables before removal.
- Cleanup dry-run never deletes files or runs commands, even with `--yes`. Confirmation distinguishes Trash from permanent tool-managed removal; simulator cleanup uses reviewed device IDs and checks live state.
- Cleanup reports measured disk space before and after, separately from estimated file sizes. Path protection checks symbolic-link ancestors, and cached plans keep their original scope and scan dates.
- Browser pages support selecting several tabs and reviewing duplicate or growing pages, protect active or unknown-current tabs, and recheck memory after closing. Slowdown actions now recheck their results.
- Native cleanup pages show progress, a Stop button and an explicit partial-results notice. Space Overview can reuse CLI measurements in the selected language without rescanning.

## 1.1.8

- Browser pages read Chrome through chrome-use (1.5.186+): the tab list without attaching to pages, memory per page only when you ask (`thermo pulse chrome --measure`, or `--watch 60` to see which pages grow), pages not measured are counted, and stale chrome-use records are no longer mistaken for hidden pages. It tells you when chrome-use's Chrome extension is out of date or its update is waiting.
- Sensors has a battery card: charge, health, cycles, power source, temperature, voltage and current.
- Keyboard: ⌘1–⌘6 switch pages, ⌘F searches sensors, diagnostics and disk categories, ⌘, opens Settings; the Edit menu works in text fields.
- Disk: "Where your disk space is" can be stopped, keeps earlier results while measuring, and says which folders it could not read. Cleanup confirmation lists the paths it will remove.
- Fans: settings apply one at a time with visible progress; invalid curve points are refused; a helper connection failure is shown as such.
- Temperatures, charts and alerts follow the Fahrenheit setting; macOS thermal pressure is shown separately from sensor temperatures.
- Many reliability fixes in diagnostics, browser checks, cleanup and the command line (details below).

## 1.1.8 — all changes

- Process diagnosis marks failed reads as incomplete; unknown launchd ownership no longer creates orphan classifications or stop-process fixes. Agent session names are excluded from end-process actions.

- Browser and diagnostic subprocess calls have bounded time, cancellation checks and capped, continuously drained output. Cancelling diagnosis skips the second sample and the tab-list fallback.

- Invalid battery registry values remain unknown instead of appearing as negative health/cycles or non-finite measurements. Charge is bounded to 0–100%; nested power state and unsigned discharge-current compatibility are retained.

- CPU and memory gauges scroll to the live resource details instead of reopening the same page.
- Sensors includes a read-only battery card for charge, health, cycles, power source, temperature, voltage and current; the Overview battery chip now leads to those details.

- Custom build output paths are checked before compilation; repository ancestors, source directories and system/installed-app locations are refused. Packaging replaces only its known products and preserves other files in the output directory.

- Packaging validates the app, standalone and embedded CLI/helper signatures, requested architecture slices and minimum OS metadata; Sparkle's requested slices are checked too.

- Watch input buffers coalesced keys and fragmented escape sequences. Direction keys arriving in pieces no longer look like a bare Escape; both CSI and application-cursor arrows are accepted.

- Watch page changes redraw the current snapshot without consuming samples or resetting the interval; tiny terminals no longer produce negative row counts. Terminal restoration occurs once on exit.

- CLI rejects flag assignments such as `--yes=false` and non-finite sampling intervals. Terminal polling clamps large waits and checks signals every 100 ms.
- `thermo settings` exposes slowdown alerts and unnamed sensor readings for agent/script access.

- Native View menu lists the main pages and their keyboard shortcuts. Language changes relabel the native menus without adding duplicates; page menu actions wait until a confirmation sheet is closed.

- Disk Cleanup cache rejects cancelled reports, duplicate IDs, negative sizes and overflowing totals. Invalid saves do not replace the last valid cache.
- Disk scans retain their starting language; changing the UI language preserves results and selections with a rescan notice instead of automatically repeating a long scan.

- Diagnostics reports retain their generation language; a language change bypasses the age cache. Reports produced in the previous language are discarded and refreshed after any active repair finishes.

- Alert settings show notification authorization separately from the alert switches, including missing permission, denied access and disabled banners. Enabling slowdown alerts requests permission, and returning from System Settings refreshes the status.

- The menu-bar hottest metric and hot alerts use the same full curated temperature scope as the open window. Default background CPU sampling remains essential-only.
- Sensors can include unnamed readings for SMC-key troubleshooting; the wider scope is released when leaving the page.

- Overview memory, process memory and swap use a shared MiB/GiB formatter in the app and CLI; disk cleanup retains decimal MB/GB. Overview details wrap instead of shrinking into a single line.

- Diagnostics retains the latest 20 operation results during the app session, including failed steps and backup locations, even after an item disappears from the inventory.
- Batch repair results list each action and its output in a scrollable sheet with a reachable Done button. A separate execution flag keeps scans and repairs mutually exclusive while views change.
- Failed diagnostic steps are written to the action log with redacted error output.

- Disk-space caches retain the original measurement time and language. Cancelled, future-dated, invalid and mismatched-language caches are rejected.
- Disk-space measurement records unreadable locations and shows a permission notice rather than silently treating them as empty.

- Disk-space measurement has a Stop action, stops when its page or window closes, keeps completed results after cancellation and does not cache partial measurements. Its cancellation token is independent of Disk Cleanup.
- A failed helper connection is labeled as a connection failure rather than claiming the helper has stopped.

- Fan policy changes run one operation at a time, show an applying state, and read back active policies even when a write fails. Pending settings for multiple fans apply in order.
- A helper version response alone no longer makes a stale policy appear active; unavailable policies have no active quick-switch highlight. Preset fan curves explicitly label Celsius.

- Offscreen screenshots do not change saved window placement; windows saved on disconnected displays reopen on screen.

- Disk-space refresh keeps previous locations visible as new readings arrive; disclosure buttons work with the keyboard.
- Label macOS thermal pressure separately from sensor temperature. Retained swap alone no longer explains a slowdown when current load and memory pressure are normal; restart advice reports current memory instead of promising a specific saving.

- Quit/end and restart recheck executable path, process start time and user identity against the captured reading; exited or replaced processes are skipped with an explanation.
- Hot notifications and alert thresholds follow the Fahrenheit setting.

- Browser page closes update memory totals, biggest-page rankings and duplicate counts; new checks cannot race a pending close, and rechecks show progress while keeping the previous result.
- App restart reports a refused quit or failed reopen; saved browser tabs are only reopened after the app launches successfully.
- Release the Mach host port after each memory reading.

- Keep unselected sessions and failed paths visible after partial cleanup; remeasure remaining data and invalidate the old scan cache.
- Completing a disk scan preserves choices made while results were arriving; stopped scans and unreadable locations are labeled as incomplete.
- Helper setup times out without restarting installation or applying queued settings; repeated setup and status checks are coalesced.

- Reject invalid and duplicate fan-curve points, preserve decimal values when editing a saved curve, and validate policies in the privileged helper.
- Disk Cleanup confirmation lists the paths that will be removed. Pending fan settings are labeled as waiting for the helper.
- Keep agent scans and fixes mutually exclusive; category batch fixes now show their commands for confirmation. Search reveals healthy matches too.

- Add the native Edit menu so Select All, Copy, Paste and Undo work in text fields.
- Search sensors by name, group or SMC key with ⌘F; switch main pages with ⌘1–⌘6 and open Settings with ⌘,.
- Temperature charts follow the Fahrenheit setting and include readings above 105°C. Empty charts explain what they are waiting for.
- Show CPU load as load per core rather than a CPU usage percentage.
- Browser checks show a stopped state and keep the previous result during a new check. Leaving the page or closing the window cancels checks for every browser; late progress from cancelled checks is ignored.
- Main-window errors are visible, with retry after sensor initialization fails. Disk Cleanup reports changed scan scopes and errors, searches paths, and provides keyboard-accessible selection and detail buttons.
- Align disk-space details with the other pages; label Settings controls for accessibility and honor Reduce Motion for page transitions and the scan halo.

## 1.1.7

- One console window for everything (the "Open Console" button in the menu bar panel, or click the Dock icon): Overview with gauges for temperature, CPU load, memory and free disk space, why the Mac is slow and the temperature trend; Sensors as a card per group; Fans; Browser pages; Disk Cleanup and AI Agent Diagnostics; Settings — all in one sidebar.
- The menu bar panel is now a glance: the live numbers, why the Mac is slow, a one-click Auto / Max fan switch, an "Open Console" button and shortcuts to its pages.
- Disk Cleanup scans everything by default and finds build output it missed: `dist`, `build`, `out`, `coverage` and similar folders in web and Python projects (skipped when git tracks them; offered for review, since they can hold renders or release builds).

## 1.1.6

- "Why is my Mac slow" says why in plain words: how much memory has been moved to the disk and that programs are waiting on it, and which program is behind it.
- Big apps are broken down: Chrome and other multi-process apps show their GPU process and heaviest pages, with how long each has run.
- Long-running apps that hold gigabytes get a concrete suggestion ("Chrome has run 31 hours and opened about 2,000 pages; restarting frees about 19 GB") and a Restart button. Thermo checks whether the app reopens its own windows; when Chrome does not, Thermo saves the tabs first and reopens them after the restart.
- Chrome page diagnosis (Overview → "查看页面", or `thermo pulse chrome`): which pages keep growing (memory, DOM nodes, or event listeners piling up), the biggest pages, duplicate tabs, and busy background workers, with a button to close a page. It lists tabs without touching them; measuring memory is a separate click, because Chrome briefly shows its "being debugged" bar while it measures. Needs chrome-use for the memory figures.
- Slowdown history: Thermo notes every minute (every five on battery) what was slowing the Mac, kept for 24 hours — a chart on the Overview and `thermo pulse history`. Cost: about 0.02% of one core.
- Slowdown alerts (Settings → "Warn me before my Mac slows down", on by default): swap growing past 8 GB, memory under pressure, one program using over 1.5 cores for 10 minutes, or thermal throttling — with who is behind it and what to do. Nothing is ever quit automatically.

## 1.1.5

- Your fan setting survives updates and restarts: the helper remembers it and puts it back when it starts (over-temperature protection still applies). Before, an update or reboot quietly returned the fans to automatic.
## 1.1.4

- Disk Cleanup has the same look as AI Agent Diagnostics: a Smart Scan home that says how much can be freed with one button for the safe part, a card per category, and pages where each item opens in place to show its sessions or files. It opens with the last scan when that is recent, instead of scanning from scratch.
- AI Agent Diagnostics has a new look: one verdict ("14 problems found, 9 can be fixed with one click"), a big Fix button that runs the safe fixes with progress and a result, colorful category cards, and plain-language problem cards with the fix right next to each; technical details are one click away.
- Disk cleanup finds more of what fills a Mac: unused Xcode simulator runtimes and simulator data (removed through Xcode's own tool), OrbStack's disk image, and chat apps' storage (Lark, WeChat, WhatsApp, Telegram, Slack…, shown with where to clear it inside the app — Thermo never deletes chat history).
- "Where the space is": the disk's used space by place — apps, app data, caches, Xcode, temporary files, Homebrew, simulator runtimes and swap — with the biggest folders in each (`thermo clean overview`).
- Sizes are what deleting would actually free, so copies that share space on disk (like Chrome's code-signing clones) no longer look huge.
- Disk cleanup moved into its own window (the popover's Disk tab now just sums up and opens it): categories on the left, build output grouped by project with when each was last used, sortable and searchable, and a detail pane with every path or session and why it is safe to remove. `Thermo --disk` opens it directly.
- Settings → AI agents (thermo-use): one click puts the `thermo` command where AI agents find it and adds the thermo-use skill to Claude Code or Codex; it shows what to ask your agent. thermo-use is part of the *-use family.
- Everything the app does is now also a command for agents and scripts: `thermo pulse quit NAME` (the Quit button on the "why is it slow" card) and `thermo settings` (menu bar text, interval, alerts, units, language, Dock icon; a running Thermo applies changes at once).
- Projects are found through the folders your AI agents and editors worked in, and "last used" comes from those sessions and git, not just file dates — so build output of projects you stopped working on is told apart from ones you use every day.
## 1.1.3

- Thermo itself stays out of the way: the "why is my Mac slow" card checks programs only while the panel is open, and each check is far cheaper (about 0.6% of one core with the panel open).
- Busy command-line programs say what they are and whose they are: "vitest ×4 · ~/code/shop · started by Claude Code" instead of a row of "node". Thermo no longer lists itself.
- Turning on fan control takes one click and your Mac password once — no trip to System Settings. After that the helper updates itself along with Thermo (it only accepts a newer helper signed by Thermo's developer), so updates never ask again.
- A fan setting you choose before the helper is ready (say, max) is applied as soon as it is.
- Turning on fan control no longer hangs on "Setting up…" when an earlier System Settings (Login Items) registration is stuck; it goes straight to the password prompt.
- After the password prompt the Fans tab picks up the new helper right away (it kept talking to the old one until Thermo was restarted).

## 1.1.2

- `thermo pulse` (also `thermo status`): why this Mac is slow, in one command — the verdict, which program is behind it, load, memory pressure and swap, thermal state, temperatures and fans; `--json` for scripts and AI agents. AI agents get it through the [thermo-use](https://github.com/leeguooooo/thermo-use) skill.
- Memory per program now counts what Activity Monitor counts (compressed and swapped memory included), so the biggest memory users are named correctly.

## 1.1.1

- Setting a fan to max now keeps it at max when the Mac gets hot. Before, over-temperature protection handed it back to automatic control, so the fan slowed down exactly when you needed it most. Other fan settings are still paused while the Mac is too hot, as before.

## 1.1.0

- **Why is my Mac slow?** The Overview now opens with a one-line answer: overloaded, too hot and throttling, or short on memory, and which program is behind it. The busiest programs are listed with a Quit button (apps quit like ⌘Q; system processes and AI agent sessions are never offered).
- Thermo has a Dock icon (Settings → Show in Dock), and clicking it opens the panel.
- When the menu bar icon is hidden behind the notch, Thermo opens its panel on launch and explains how to make room.
- New **Agents** tab and `thermo agents` command: diagnoses the AI coding agents on this Mac (Claude Code, Codex, Cursor, Gemini). Finds hooks and MCP servers whose programs are missing, plaintext credentials in MCP configs, plugins that are enabled but not installed, broken skill symlinks, launch agents stuck in a restart loop or pointing at deleted programs, and agent processes that leaked or still run a deleted binary. Read-only; secrets are redacted.
- AI agent diagnostics can now fix and uninstall: remove broken skill links, MCP servers, hooks and launch agents, stop launchd restart loops, end leftover processes, disable or uninstall plugins. Every action shows the exact steps first, backs up config files and moves files to the Trash.
- New diagnostics window (sidebar of checks, item list, details with suggestions and actions); the popover tab is now a summary.
- Disk cleanup (`thermo clean`, Disk tab). It recognises what AI tools leave on disk:
  - Claude Code, Codex and Gemini CLI sessions, grouped by project;
  - Cline, Roo and Kilo tasks;
  - editor chat data for projects that have been deleted;
  - agent worktrees;
  - old CLI and plugin versions and agent scratch folders;
  - Ollama, Hugging Face and LM Studio models.

  It also covers developer caches, Xcode, project build output, browsers and logs. Sessions that are still running, apps that are open and anything with unsaved work are skipped. Caches are deleted; your data goes to the Trash.
- Thermo speaks Chinese: Settings → Language (System / English / 简体中文). The `thermo` command stays English unless `THERMO_LANG=zh`.

## 1.0.4

- Over-temperature protection no longer throws away your fan settings: fans go back to automatic control while the Mac is too hot, and your fixed speed or curve comes back once it has cooled down.
- Apple Silicon: the protection triggers at 110 °C instead of 95 °C. These chips normally run their cores at 100–115 °C under load, so the old limit kept switching curves off for no reason.
- A single brief temperature spike no longer triggers the protection; it has to last a few seconds.

## 1.0.3

- Apple Silicon: switching a fan back to Auto works again (it left the fan at its last manual speed); if returning to Auto ever fails, every fan is reset to system control.
- Apple Silicon: setting a fixed speed or curve no longer reports a timeout while the fan control is being unlocked.

## 1.0.2

- Thermo now lives at app.leeguoo.com/thermo — downloads and updates come from there.
- After an update, the fan helper restarts itself on the new version (fans briefly return to automatic control).
- Product screenshots render the panel tabs correctly.

## 1.0.1

- Apple Silicon: fans under system control are no longer shown as "manual", and returning a fan to Auto restores the system's own fan mode.
- Battery temperature and health on recent macOS versions.
- Lower background CPU use on Apple Silicon.
- Sensors that share a name are now listed separately.

## 1.0.0

- Menu bar app showing CPU/GPU temperature, fan speed or system power, with a 10-minute history chart.
- Every SMC temperature sensor with readable names and groups; power, voltage, current and battery health.
- Fan control: fixed speed or temperature curve (Quiet / Balanced / Performance / custom), driven by CPU, GPU or the hottest sensor.
- Safety: fans return to automatic control when any CPU/GPU sensor reaches 95 °C, and whenever the helper stops.
- `thermo` command-line tool: overview, live `watch` view, JSON/CSV output, raw SMC access, fan control.
- High-temperature alerts and launch at login.
