# 开发史与遗留事项

> 维护规则：每个 Slice/修复合并 main 时追加时间线一行；关键决策与遗留事项随时增删。接手小任务前先扫一遍「遗留事项清单」。

## 时间线（2026-08-20 起）

| 阶段 | 范围 | 执行 | 合并点 |
|---|---|---|---|
| S1 捕获核心 | 窗口 + Universal Input + List + SQLite/FTS + Enter 创建 + 输入即搜索 + ↑↓ 焦点 | Sonnet | `a0394f9` |
| S2 键盘模型 | ←→ Priority、Space Resolve、Enter Inline Edit（含 IME 防误触）、Focus 继承 | Sonnet | `894e1e5` |
| S3a Scope 基础 | schema v2（project 表）、Scope Bar、⌘Number、主菜单、作用域化创建/搜索 | Sonnet | `749083e` |
| S3b Project 管理 | All View 分组/折叠、Rename/Delete、chip 拖拽排序、Record 移动（M/右键） | Grok 4.6 | `3574cc3` |
| S4a 排序与 Show Resolved | 三种全局排序、Resolved 分组与样式、Reopen、焦点稳定 | Grok 4.6 | `3d0a3f4` |
| S4b Trash 与 Undo | 软删除（⌫）、⌘Z Undo、Trash Secondary Surface、永久删除 | Grok 4.6 | `8ab5d1b` |
| S5 应用形态 | xcodegen 工程入库、驻留/激活、菜单栏、Launch at Login、`--ui-smoke` | Grok 4.6 | `f0c6226` |
| S6 CloudKit 同步 | CKSyncEngine、schema v3、无损冲突合并、`--sync-probe` 双库验证 | Grok 4.6 | v0.2.0 |
| fix 窗口坍缩 | 修复主窗口 fitting-size 坍缩到 28pt + ui-smoke 几何断言 | Grok 4.6 | `b31233e` |
| feat 多选与拷贝 | 列表多选（⇧↑↓/⌘A/⇧⌘点击）+ 批量 ⌫/Space/←→/Move、批量删除单步 Undo、⌘C 拷贝内容、All View 拖拽行改 Project | Fable | `30f1cbb` |
| feat R2 沉浸与多行 | 无标题沉浸窗口、iCloud Sync 菜单开关 + 账号不可用离线标签、列表多行换行（Priority/时间与首行基线对齐）、输入框超长单行尾部聚焦、拖 Record 到 Scope Bar chip | 流水线：Fable 协调/验收，Grok 4.6 执行，GPT-5.6-sol 审查 | `f780dcf` |
| feat R3 玻璃视觉与 Settings | 全窗 sidebar 材质 + fullSizeContentView、玻璃胶囊 Universal Input/Scope chip、透明行背景与行距、Record 字号偏好即时生效、Settings 窗口（⌘,：字号/Launch at Login/iCloud Sync，替代 App 菜单开关）、Titlebar 系统填充隐藏（Tahoe workaround） | 用户直连迭代（护栏文件），Fable 验收合并 | `633ea09` |
| feat R4 UI chrome 对齐 | 描边 chip 与 symbol 切换（Resolved 眼睛 / `+` 圆形）、排序 chip 与 Resolved 同侧、菜单栏实心图标左键开窗右键菜单、多行自适应 Inline Edit、Scope Bar 仅横向滚动 + 尾部渐隐 + `+` 固定右缘、行选中上下对称、Trash 行正常色且无默认分组、去掉 Resolved 标题行、Record 字号跟随系统 body | 用户直连迭代，Fable 执行/验收合并 | `020e007` |
| fix R19 行高与滚动规则 | 最后一行编辑提交后列表跳一行、焦点行被藏到底栏下。根因是 `usesAutomaticRowHeights`：`reloadData()` 先把全部行高重置为估算值再在显示时实测，滚动偏移在中间被夹住。两张表改为显式行高（delegate `heightOfRow` ← `RecordCellView.displayHeight`，与绘制同一套 `WrappingTextFieldCell.cellSize` 测量 + 按内容缓存，单行快路径；编辑行走 `editingRowHeight`），编辑提交不再 `reloadData`，改宽只 `noteHeightOfRows`（推迟一轮 run loop 避免 delegate 重入警告；live resize 只重测可见行）。`scrollRowToVisible` 重写为"行落在两条栏之间"。冒烟：末行编辑提交 / Resolve / ⌫ 后焦点行都在栏之间、cell 文字宽度 = 测量假定宽度 | Fable 直接修 | （待填） |
| ui R18 时间列显示日期 | 去掉 Today/Yesterday，时间列一律 `MMM d`（跨年 `MMM d, yyyy`）；用户明确此类小修不跑冒烟 | Fable 直接修 | `f34e788` |
| ui R17 边距定稿 | `windowInset` 8 → 12（用户：8 太极限），`contentInset` 16 → 12 与之同步：选中块回到 Input 同宽、列表文字与 All 字母同轨（文字轨 21）、底栏高 46 | Fable 直接修 | `c9f34ce` |
| ui R16 窗口边距令牌 | 新增 `Theme.Size.windowInset`（8）：窗口边缘 → 最外层 chrome（Input、Scope Bar 轨道与 "+"、底栏按钮/提示与离底边、Trash 两条栏、组头 chevron 对齐 "+"），与列表轨道的 `contentInset`（16）解耦，调外圈不动列表；冒烟几何断言改读 `windowInset`，"列表文字 = All 字母"只在两令牌相等时断言。顺带修冒烟竞态：离开 Trash 后 ↓ 可能抢在异步重搜之前、随后 reload 清掉选区——新增 `settledSearchGeneration`，冒烟等 `smokeSearchSettled` | Fable 直接修 | `a057eb0` |
| ui R15 Trash 收口 | Trash 去掉提示组（Restore 只走鼠标，⌫ 仍需确认；Return 本来就未接动作，旧提示 `↵ Restore` 是误导）；Back 改 `ScopeChipButton.style = .plain`（无底无框、`Ink.secondary`）；结构与主表面一一对应 | Fable 直接修 | `24d6851` |
| ui R14 底栏留白、Trash 表面、改宽丢选区 | 底栏/Trash 动作栏按钮离底边 `contentInset`（栏高派生为 26+16+8=50），提示组对齐按钮中心线；Trash 头部改 `‹ Back` 填充 chip + "Trash" 标题（落在 16pt 轨道）；Trash 行改自动行高、与主列表同内边距/行距（冒烟断言两表单行等高）；**修 bug**：自动行高表在 `setFrameSize` 里同步 `reloadData()` 后 AppKit 会清掉重选的选区——每次非 live 改宽（`setFrame`、zoom、live resize 结束）Row Focus 都丢；改为推迟到下一 run loop 重载（`reloadData(forRowIndexes:)`/`noteHeightOfRows` 不缩行，不能替代），冒烟新增主/Trash 改宽后选区保留断言 | Fable 直接修 | `18c6560` |
| ui R13 底栏按钮与提示 | 底栏/Trash 动作栏按钮改 `ScopeChipButton.style = .filled`（圆角 `Theme.Radius.control` 6、底色 `Ink.selection`、选中 `Ink.outline`、无描边），与 Scope Bar 胶囊区分；键帽改 SF Symbol（`return`/`space`/`arrow.down`，`esc` 留文字）；提示精简为每状态两条（去掉 `⌫ Trash`、`←→ Priority`、Trash 的 `⌫ Delete`）；冒烟断言样式/圆角/提示文本 | Fable 直接修 | `90b67bf` |
| feat R12 撤销与排序 | ⌘Z 覆盖 Resolve/Reopen 与 Move（改 Project），与 Move to Trash 同一栈；去掉 `M` 快捷键（Move 只走右键/拖拽）；排序去掉 Oldest，排序 chip 改为 Newest ⇄ Priority 两态切换、不再弹菜单；冒烟新增撤销链路与排序切换断言 | Fable 直接修 | `b0f91cf` |
| ui R11 上屏反馈 | 用户上屏后反馈：滚动条白底灰条不自动隐藏（legacy 样式被系统首选覆盖）→ `OverlayScrollView` 强制 overlay；去掉最后一条分割线；组头 chevron 与 "+" 同心（按 chip 真实宽度算 nudge）；选中块左右边缘锚定 Input 胶囊（窗口坐标），滚动条不影响 | Fable 直接修，快照验收 | `f74be20` |
| ui R10 视觉语言 | 参考 tinycast 的设计系统后确立 docs/ui.md：`Theme.swift` 单一令牌源（Spacing/Radius/Size/Ink/Typography，快照逐字节一致）；墨色透明度阶梯代替系统灰；Row Focus 改 10% 墨色圆角块、文字不反白；圆角阶梯；Input 下唯一发丝线，列表占满并从透明的 Scope Bar / 底栏下穿过，上下边缘溶解（滚动驱动的 `CAGradientLayer` 遮罩）；底栏左功能组（Resolved/Sort/Conflicts/Trash）右按键提示组 | 流水线：令牌收口 1 个执行者先行，再 2 个执行者按 Views / Surfaces 边界并行；Fable 看快照验收 | `279e106` |
| feat R9 发布准备（第一轮） | CloudKit 容器环境按构建配置取值（Debug=Development / Release=Production）；File 菜单导出（JSON 全量 / `VACUUM INTO` 快照 / Show Data in Finder）；Settings 显示上次同步成功时间与最近终端错误（无轮询）；搜索规模复查（LIKE 保留，见性能基线）；`--ui-smoke --snapshot-dir` 像素快照与像素对齐断言；**像素审查修复**：换行行在窗口改宽后不重测（reload 重测，live resize 中只用 grow-only note）、显示态测量改用 `NSTextFieldCell.cellSize` 与绘制一致（304 pt 时 boundingRect 少算一行导致末行被裁）、Input 取得焦点时清掉残留的灰色选区、Inline Edit 编辑器 2 pt 左偏、Trash 长文本裁切改省略号；冲突中心（schema v4 `conflict_of` 随 CloudKit 同步、`listConflicts` / `resolveConflict` 无损三选、行内弱化 Conflict 标记、底栏 N conflicts 过滤 chip、右键 Resolve Conflict） | 流水线：4 个执行者并行（worktree），Fable 审阅/集成/四道门/文档 | `a3dc4f6` |
| polish R8 遗留收口 | 删 `onRequestEscape` 死闭包 + Trash 表面 Esc 冒烟；`ClearTableRowView`/`frameOfCell` 复审（26.6 仍需要，去掉后文字轨 25→31）；`TitlebarBackdrop` 复审（26.6 上为空操作，保留并加探针断言作为复审机制）；warm 激活计时进冒烟（中位 11 ms，100 ms 门槛）；`NSOutlineView` 微基准后否决 | Fable 逐项执行 | `4f5cb75` |
| ui R7 键位与底栏结论 | `RecordTableView` 改按 `specialKey`/字符判定（修非美式布局 `M`，⌘M 显式排除）；冒烟新增 `stepUtilityBar` 并修正 `←` 事件缺字符；**底栏换平台 `NSButton` 的实验做完并否决**（A/B 与微基准见性能基线）——底栏与 Trash 动作栏保留 `ScopeChipButton`，排序菜单改为点击时构建 | 流水线：2 个执行者并行（worktree）做实验版，Fable A/B 计时、微基准、最终从 main 重开分支只保留有价值的部分 | `e12fd37` |
| perf R6 启动与体积 | 同步引擎/状态栏项推迟到首帧后、诊断运行器 `#if DEBUG`、Release 仅 arm64 + `-Osize`、chip symbol 缓存与 chip 复用、cell 文本测量缓存、DateFormatter 复用、SQLite WAL + synchronous=NORMAL、折叠集每次重建只读一次 | 流水线：4 个执行者并行（各自 worktree），Fable 审阅/集成/四道门 | `dafd4f3` |
| refactor 基础瘦身 | 删死代码（Resolved 标题行类型与 cell）、`Dialogs` 收口四个弹窗、`RecordStore.batch` 收口扇出、`Preferences` 收口四个持久键、`MainViewController` 拆为核心 + `+Records` + `+Projects` + `+Smoke`（1574 → 658 行）、Project 列表刷新合并为一条路径、源文件按层分目录（App/Surfaces/Views/Model/Storage/Sync/Diagnostics）；新增 docs/ARCHITECTURE.md，SPEC v0.2（角色泛化、代码组织、平台组件优先），CLAUDE/README 刷新 | Fable 执行，用户验收 | `32ad30a` |

角色分工（首个周期）：Fable 协调/审阅/合并，Grok 4.6 xhigh 主力编码（S3b 起），Sonnet 早期编码与文档；R3 起用户直连迭代、Fable 执行与验收。每个合并点都经过独立 build/test/冒烟。现行角色定义见 SPEC §1。

## 关键技术决策（为什么是现在这样）

1. **中文搜索用 LIKE 而非 FTS5 MATCH**：unicode61 不切分 CJK；trigram 要求查询 ≥3 码点，排除 1–2 字中文词。`record_fts`（trigram）镜像仍完整维护，为大数据量时切换 MATCH 排名预留。实测 10k 行 LIKE ~2ms（预算 50ms）。见 RecordStore.swift 顶部注释。
2. **ListRow / ListRowIndex 是唯一的表行↔Record 映射层**：分组、Resolved 小节、导航跳过非 Record 行、焦点继承全部走它。任何列表结构改动先改这个纯函数层并补测试，禁止散落手工换算索引。
3. **焦点继承规则**（Resolve/删除后）：下一条可见 → 上一条 → 回 Input；Show Resolved 开启时只在 Open 序列上走（焦点不跟进 Resolved 组）。纯函数在 RowFocus.swift。
4. **Undo 只覆盖 Move to Trash**：窗口级 UndoManager 由 AppDelegate 路由（文本编辑时 field editor 的栈优先）。undo/redo handler 在回调开头同步注册反向动作——store 写入是异步的，不能在 completion 里注册（会开新 undo 组）。
5. **同步元数据信封含"共同祖先"**：`ck_system_fields` 存 system fields + 上次同步的字段快照。没有祖先值无法区分"两端改了不同字段"（自动合并）与"同字段冲突"（无损处理）。冲突规则表见 ConflictMerger.swift 与 docs/SCHEMA.md。
6. **窗口坍缩事故（重要教训）**：顶层 surface 四边用 Auto Layout 钉在 content view 上会让 NSWindow 持续吸附 fitting size——约束链没人提供宽度时窗口坍缩到 28pt，`setContentSize` 会被弹回，`preferredContentSize` 又会把尺寸钉死。现方案：顶层 autoresizing + 挂载后 setContentSize + `constrainFrameRect` 套 minSize。**UI 几何类改动必须在 UISmokeRunner 加断言。**
7. **xcodeproj 入库**：为了 clone 即开。project.yml 是唯一权威，改配置必须走它（含 Xcode 界面里点的签名设置——点完要回填）。源文件按目录收录，但生成的 pbxproj 逐文件列出，所以增删 Swift 文件也要重新生成。
8. **留在 AppKit，不迁 SwiftUI/GPUI**（2026-08-22 复核）：键盘语义与启动体积是产品核心，AppKit 是唯一能同时满足的选择；理由与对比见 ARCHITECTURE §7。打磨方向是减少自绘、多用平台组件（ARCHITECTURE §8 候选清单）。
11. **内存口径（2026-08-22）**：Activity Monitor「Memory」列 = `phys_footprint`（`footprint -p <pid>`），不是 RSS。Inbox Release 25 MB（最小 AppKit 窗口 17 MB）；tinycast 官网截图 72.6 MB 是同一口径。之前记的 91 MB RSS 含共享框架页，不可比。
12. **视觉语言来源（R10）**：tinycast（SwiftUI，57k 行，macOS 26+）的 `docs/ui.md` + `Theme.swift` 是很好的"设计系统写法"范本——一段话说清外观、一条墨色阶梯、令牌单源、不可变项清单、边缘溶解参数（顶 栏高+32 / min 0.15，底 栏高+28 / min 0.25）。我们采纳了写法与阶梯思想，**没有**采纳它的无边框面板形态、自绘对话框和 latest-only 策略（常驻窗口是 PRD 定的产品形态；平台组件优先与 macOS 14 下限是既定决策）。
10. **性能审计方法（2026-08-22，留作后续对比）**：启动用"spawn → 首个 layer-0 窗口出现"计时（轮询 `CGWindowListCopyWindowInfo`，脚本 ~40 行，不入库），对照一个 56 KB 的最小 AppKit 窗口程序作平台底价；体积看 `strip -x` 后的单架构二进制；内存看启动 2 s 后的 RSS；剖析用 xctrace Time Profiler，**注意 xctrace `--launch` 按 bundle id 经 LaunchServices 取包，会拿到 DerivedData 里的旧 Debug 包——要复制 Release 包改 CFBundleIdentifier 并 ad-hoc 重签后再录**。决策记录：最低版本保持 macOS 14、整窗 behind-window 模糊保留（产品选择）、只发 arm64。
9. **控制器按关注点拆 extension 文件而不是抽新层**：`MainViewController` 1574 行拆为核心 + `+Records` + `+Projects` + `+Smoke`，共享成员模块内可见。没有引入 Coordinator/Presenter——同一个 `self`，零间接层，拆分只为导航与审阅范围。弹窗进 `Dialogs`、键进 `Preferences`、扇出进 `RecordStore.batch`，三个"重新加载 Project 列表"变体合并为 `reloadProjectsAndSearch`。

## 遗留事项清单

### 发布/分发前必须

- [ ] CloudKit 容器切 Production 并部署 schema（entitlements 中 `icloud-container-environment` 现为 Development）。
- [ ] Launch at Login 在 /Applications 安装形态下人工确认一次（开发目录 ad-hoc .app 的 SMAppService 注册可能被系统拒绝）。

### 已知小缺陷 / 打磨

- [x] `M`（移动 Project）用硬编码 keyCode 46，非美式键盘布局可能失效 —— R7 改为按字符/`specialKey` 判定。
- [x] `RecordTableView.onRequestEscape` 死闭包 —— R8 删除，并补 Trash 表面 Esc 冒烟。
- [ ] Inline Edit 提交遇 DB 写入失败时编辑文本随弹窗丢弃（应保留编辑态让用户重试/复制）。
- [ ] ScopeChipButton 选中态用 CGColor 快照，系统深浅色热切换时不会自动跟随（chip 重建频繁，影响小）。
- [ ] Trash 分组组头画了 ▼ 但不可折叠（PRD 对 Trash 无折叠要求，视觉上有误导）。
- [ ] Utility 栏在 480pt 最小宽度下略挤（Resolved / Sort chip + 离线标签 + Trash），离线标签会被压缩但无溢出处理。
- [ ] 已删除 Project 的折叠状态键残留在 UserDefaults（无害未清理）。
- [ ] All View 拖拽改 Project（含拖到 Scope Bar chip）无自动化覆盖（ui-smoke 不合成鼠标拖拽事件），依赖人工冒烟；drop 目标解析的纯逻辑已有单测（ListRowIndex.dropTargetGroup）。
- [ ] iCloud 离线标签只在启动时一次性检测 accountStatus——会话中途登录/登出 iCloud 不刷新；iCloud Sync 开关改动需重启生效（CKSyncEngine 无 stop API，属既定简化）。R9 起 Settings 显示上次成功同步时间与最近终端错误（`Preferences.lastSync*`，`.inboxSyncStatusDidChange`）。
- [ ] 开发环境 CloudKit 容器里有一条探针记录 `manual-probe-1787274876-786` 前缀类似的测试数据，同步到真实库后可在 App 内 ⌫ 删除。

### 性能基线（Release，Apple Silicon，2026-08-22；方法见决策 10）

| 指标 | 最小 AppKit 窗口 | R5（优化前） | R6（优化后） |
|---|---|---|---|
| spawn → 出窗 中位数 | 180–186 ms | 294 ms（.app）/ 258 ms（裸） | **278 ms（.app）/ 245 ms（裸）** |
| RSS（启动 2 s 后，含共享框架页） | 78 MB | 92 MB | 91 MB |
| **phys_footprint**（Activity Monitor「Memory」列口径，`footprint -p`） | 17 MB | — | **25 MB**（12 线程） |
| 发布二进制（strip 后） | — | 2.4 MB universal 未 strip；单架构 754 KB | **569 KB**（arm64，`-Osize`，无诊断代码） |
| 单条写事务 | — | 0.33 ms（rollback journal） | 0.05 ms（WAL） |

**R7 实验：底栏换平台按钮（否决）**。把 Utility 栏（Resolved 切换 `.accessoryBar`、排序 `NSPopUpButton`、Trash `.accessoryBarAction`）与 Trash 动作栏换成 `NSButton`，三轮交替 A/B：冷启动 **+10 ms**；排序改 `NSButton` + 懒建 `NSMenu` 后仍 **+3–5 ms**。控件微基准（单独冷进程、上屏 layer 路径、Release）：首绘相对自绘 chip，`.accessoryBarAction` +3 ms、`.accessoryBar` toggle +8 ms、`NSPopUpButton` +15 ms；每次重绘 chip 1.2 ms、accessory 按钮 3 ms、pop-up 5–6 ms；**成本按实例累加不按种类摊还**（10 个实例：chip 首绘 28 ms / 每次重绘 3.6 ms，accessory 按钮 45 ms / 16.7 ms）。原因：系统 bezel 每个实例都走 CoreUI 素材 + Tahoe 玻璃材质的绘制路径，自绘 chip 只是一个 CALayer 边框 + 一段富文本。结论（用户拍板）：底栏只需要触发动作、尺寸对齐、颜色跟随深浅色，样式没有特殊要求，而 `ScopeChipButton` 本来就为 Scope Bar 维护——**全 App 统一用自绘 chip，Scope Bar 更不换**（随 Project 数线性增长）。平台组件优先原则不变，但"平台组件 = 更快"对轻量自绘不成立，换之前先量。

**R9 搜索规模复查**（Release，中英各半语料，20 次 p50/p95，`store.search` 端到端）：

| N | 英文常见词（~10% 命中） | 英文罕见词 | 中文 1 字 | 中文 2 字 | 中文 3 字 | 中文 5 字 | 空词（全量） |
|---|---|---|---|---|---|---|---|
| 10k | 2.5 / 2.8 ms | 1.8 / 1.9 | 2.9 / 3.1 | 2.7 / 2.9 | 2.4 / 2.6 | 2.1 / 2.3 | 7.2 / 7.4 |
| 50k | 14.9 / 15.0 | 11.2 / 11.4 | 17.2 / 17.6 | 15.9 / 16.1 | 14.5 / 14.6 | 13.0 / 13.5 | 38.7 / 39.1 |
| 100k | 32.7 / 33.5 | 24.9 / 25.2 | 36.8 / 37.2 | 34.3 / 35.0 | 31.6 / 32.0 | 28.6 / 29.2 | 80.0 / 81.1 |

LIKE 扫描约 2.5 µs/行，与命中数无关；返回行另加约 0.55 µs/行。FTS5 MATCH（trigram，≥3 码点）在常见词上与 LIKE 持平或更慢（100k 英文常见词 36 vs 33 ms p95），只在低命中词上赢（罕见词 0.1 ms、中文 5 字 13 ms）——而最常见的 1–2 字中文查询它根本不能服务。**结论：保留 LIKE**，100k 时所有词条 p95 仍 ≤ 40 ms（预算 50 ms @10k）。空词全量 100k 超预算（80 ms），但成本在物化 10 万个 Record 而非谓词（仅扫描 23 ms），若真有 10 万级库，解法在列表分页而非搜索策略。100k 时库文件 54.5 MB，其中 `record_fts*` 22.9 MB（42%）只写不读——未来可考虑去掉镜像省体积。语义提醒：`case_sensitive_like` 关闭时 LIKE 只对 ASCII 不分大小写，trigram MATCH 折叠 Unicode 大小写；若将来混用须 `MATCH ? AND content LIKE ?` 保证结果集一致。基准 harness（跳过式 XCTest）按 SPEC §4 不入库，存于会话 scratchpad，方法：按批 5k 行事务插入、每词 20 次取 p50/p95。

**R8 warm 激活**（PRD §17.1，App 自身那一段：`presentMainWindow` → 窗口可见且光标在 Input，冒烟内 5 次采样）：**中位 11 ms**（9.5–13）。Dock/⌘Tab/启动器到 `presentMainWindow` 之间是系统的时间，不在此数内。冒烟门槛 100 ms。

**R8 `NSOutlineView` 微基准**（5 组 × 10 行，view-based，上屏）：首绘 `NSTableView` 30 ms vs `NSOutlineView` 38 ms；warm `reloadData` 9.4 vs 11.0 ms；滚到底再回 4.0 vs 4.9 ms；折叠+展开一组 9.4 ms（现方案 rebuild + reloadData）vs **1.5 ms**（原生，含动画）。结论：否决——赢的是低频操作，输的是首绘与每次按键 reload 的热路径，且 ←→ 与 Priority 冲突、拖拽/多选/焦点继承都要重写。若将来要折叠手感，在 `NSTableView` 上改用 `insertRows/removeRows` 即可拿到同量级收益。

剩余超出底价的 ~65–100 ms 去向（R6 Release 剖析）：`NSWindow` 创建 26 ms（macOS 26 标题栏材质，基准程序同样要付）、`MainViewController` 构建 23 ms（其中 5 个 `ScopeChipButton` 11 ms ≈ 2 ms/个）、首次布局绘制与 `focusInputAtEnd` 的 field editor 实例化 ~10 ms、主菜单/状态栏等杂项。下一步最大的单项就是 chip 换平台按钮。

### UI 打磨候选（平台组件优先，按风险从低到高；详见 ARCHITECTURE §8）

- [x] ~~Utility 栏与 Trash 动作栏的 `ScopeChipButton` 换成 `NSButton`~~ —— R7 实验后否决，保留 chip（见性能基线）。
- [x] `RecordTableView` 硬编码 keyCode 改字符判定（R7）。
- [x] `ClearTableRowView`/`frameOfCell` 与 `TitlebarBackdrop` 复审（R8，macOS 26.6）：前者仍需要（去掉后文字轨偏 6 pt）；后者在 26.6 为空操作但为 27 保留，冒烟断言"标题栏无可见系统材质"即复审机制。
- [x] ~~All View 分组折叠评估 `NSOutlineView`~~ —— R8 微基准后否决（见性能基线）；折叠手感如需提升，用 `insertRows/removeRows` 局部更新。
- [x] ~~Scope chip 最后评估~~ —— 同上，bezel 成本按实例累加，保留自绘。
- [ ] 替换前先量一次激活时延与二进制体积作为基线（PRD §17.1，ARCHITECTURE §10）。

### 像素审查（R9，`--ui-smoke --snapshot-dir`，浅/深色 × 480/720/1100 × 普通/Resolved/Trash/Row Focus/Inline Edit）

- [x] 换行行高在窗口改宽后滞后/留白 —— 修复（`RecordTableView.setFrameSize` 宽度变化 reload）。
- [x] 480 宽时长文本末行被裁 —— 修复（测量改用 cell 自身的 `cellSize`）。
- [x] Input 焦点下残留灰色选区 —— 修复（`focusInputAtEnd` / 点击输入框时 `deselectAll`）。
- [x] Inline Edit 文字比显示态左 2 pt —— 修复（编辑器 `lineFragmentPadding = 2`）。
- [x] Trash 长文本裁切无省略号 —— 修复（cell `isScrollable = false`）。
- [ ] **需人工确认**：深色模式下 Universal Input 在快照里是纯白平面。快照经 `cacheDisplay` 离屏绘制，`NSGlassEffectView` 的玻璃由窗口服务器合成，浅色快照里它同样是纯白——大概率是快照局限而非缺陷，但只有上屏才能确定。
- 快照局限：标题栏在 `contentView` 之外不入图；behind-window 模糊不入图。

### 产品待定（需要用户拍板，不要擅自改）

- [ ] **冲突中心交互（R9 引入，等评审）**：Keep This / Keep Other 把放弃方移入 Trash 而非永久删除；解决不进 ⌘Z 栈；"N conflicts" chip 是会话态过滤（不持久化）；Conflict 标记占用时间列位置。PRD §15.3 允许"弱化 Badge 或 Conflict Center"，这里选了前者。
- [ ] **导出 JSON 顶层键用 snake_case**（`format_version` 等），与列名一致；若更想要 camelCase 是一行改动。

- [ ] All View 中 Resolve 后的"下一条 Open"会跨 Project Group 边界继承焦点——如果期望限制在组内，是产品决策。
- [ ] 从 All View 空白处右键 Create Project（PRD §7.5 提及）尚未实现，目前只有 Scope Bar 的 `+`。
- [ ] 新建 Project 后不自动切换到该 Scope（一行改动，等手感反馈）。
- [ ] 切换 iCloud 账号时本地库不隔离（保留并向新账号重放 pending）——多账号场景未定义。

### S7 计划内未做

- [x] PRD §17.1 激活时延基线 —— R8 冒烟内测量 App 自身部分中位 11 ms（见性能基线）。
- [x] Accessibility —— R9 只做平台默认 + 简单配置（自定义控件的 label/role/value），用户决定不投入更多。
- [x] 数据导出入口 —— R9：File ▸ Export as JSON… / Export Database Snapshot… / Show Data in Finder（格式见 SCHEMA.md「导出格式」）。
- [x] 冲突中心 / Badge UI —— R9：schema v4 `conflict_of` 随 CloudKit 同步，行内弱化 Conflict 标记 + 底栏 "N conflicts" 过滤 chip + 右键 Resolve Conflict ▸ Keep This / Keep Other / Keep Both（无损：放弃方进 Trash，不入 ⌘Z 栈）。设计细节见 docs/RELEASE.md 第二轮。已知限制：原始记录的标记依赖其副本也在当前列表里（搜索词只命中一半时只标一半）。
- [x] FTS 复查 —— R9：100k 行 LIKE 仍在预算内，MATCH 不能服务 1–2 字中文，保留 LIKE（见性能基线）。新遗留：`record_fts` 镜像占库文件 42% 却不在查询路径上，可考虑移除以省体积。
