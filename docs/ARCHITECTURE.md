# 架构与代码组织

> 目标读者：任何要改代码的人或 Agent。读完应能回答"这个改动该落在哪个文件、会碰到哪条不变量、要补哪类验证"。产品语义以 PRD 为准，工程守则以 SPEC.md 为准，本文只描述**现状结构与原因**。

## 1. 定位与设计目标

Inbox 是一个只做一件事的 macOS 工具：用键盘把 Record 记下来、找出来、整理掉。工程上的三条硬目标：

1. **轻**：零第三方依赖，纯 AppKit 代码，Debug 裸二进制约 2.3 MB；启动只链系统库，不拉任何运行时框架。
2. **快**：所有高频操作先落本地 SQLite、UI 下一帧反馈；搜索 10k 行 ≈ 2 ms。
3. **键盘优先**：`↑↓/←→/Enter/Space/⌘Number` 的语义由 responder chain 精确控制，这是选择 AppKit 而非 SwiftUI 的根本原因（见 §7）。

## 2. 分层

```
启动        main.swift → AppDelegate（窗口、主菜单、状态栏、Undo 路由、Settings）
            LaunchConfiguration（--ui-smoke / --sync-probe / --db-path / --defaults-suite）
            UISmokeRunner · SyncProbeRunner（进程内验证模式）

界面        MainViewController  (+Records / +Projects / +Smoke)   TrashViewController
            UniversalInputView · ScopeBarView · RecordTableView
            RecordCellView · GroupHeaderCellView · ScopeChipButton · GlassCapsuleView
            Dialogs（所有模态弹窗） · Preferences（所有 UserDefaults 键）

纯逻辑      ListRow（ListRows / TrashRows / ListRowIndex） · RowFocus · RecordSort · Scope
            Record · Project（值类型模型） · Export（JSON 导出文档与 Codable）

存储        RecordStore（+Sync） · ProjectStore · SQLiteDatabase

同步        SyncEngine（CKSyncEngine 协调） · CKRecordMapping · ConflictMerger · SyncTypes
```

目录与分层一一对应（`Sources/Inbox/`）：

```
App/          main · AppDelegate · GlobalHotKey · LaunchConfiguration · Preferences · SettingsViewController
Surfaces/     MainViewController(+Records/+Projects/+Smoke) · TrashViewController · Dialogs
Views/        UniversalInputView · ScopeBarView · ScopeChipButton · RecordTableView · RecordCellView
              GroupHeaderCellView · GlassCapsuleView · RecordDragTypes
Model/        Record · Project · Scope · ListRow · RowFocus · RecordSort · Export
Storage/      SQLiteDatabase · RecordStore · RecordStore+Sync · ProjectStore
Sync/         SyncEngine · SyncTypes · CKRecordMapping · ConflictMerger
Diagnostics/  UISmokeRunner(+Chrome/+Flows/+Snapshots) · RecordStore+Smoke · SyncProbeRunner
```

依赖方向自上而下；`Model/`、`Storage/`、`Sync/` 的纯逻辑文件不 import AppKit，因此能进 `swift test`（`project.yml` 的 InboxTests target 按目录路径逐文件列出了这些源文件——新增纯逻辑文件要同步加进去）。新文件放进它所属的层；一个文件跨两层说明职责没切干净。

## 3. 文件职责速查

每个源文件一行；新增/删除文件时同步这张表（并 `xcodegen generate`）。

| 文件 | 负责 | 不负责 |
|---|---|---|
| **App/** | | |
| `main.swift` | 进程入口：`--ui-smoke` / `--sync-probe` 分流，否则启动 AppKit | — |
| `AppDelegate.swift` | 窗口创建与尺寸约束、主菜单（App/File/Edit/Go）、File 导出入口（JSON / 快照 / Finder 定位）、`⌘Number`、状态栏项、Undo/Redo 路由（field editor 优先于业务撤销栈）、Settings 窗口、同步引擎启停 | 任何 Record/Project 业务 |
| `LaunchConfiguration.swift` | 命令行参数解析（冒烟/探针路径、defaults suite、快照目录） | — |
| `GlobalHotKey.swift` | `⌥Space` 系统级热键：Carbon `RegisterEventHotKey` 的零依赖封装（非独占注册，无需辅助功能权限） | 唤起/隐藏策略（`AppDelegate`） |
| `Preferences.swift` | UserDefaults suite 切换；lastScope / collapsedGroups / sortOrder / showResolved / syncEnabled / globalSummon / lastSync*；行字号与行高常量（逻辑测试也用） | 视觉令牌（`Theme`） |
| `SettingsViewController.swift` | Inbox Settings 窗口：Launch at Login、⌥Space 唤起、iCloud Sync、只读同步状态；自绘居中标题 | 同步逻辑 |
| **Model/** | | |
| `Record.swift` / `Project.swift` | 纯数据结构与 `Priority` / `RecordStatus` 枚举 | 持久化 |
| `Scope.swift` | All / Project 作用域枚举 | — |
| `RecordSort.swift` | Newest ⇄ Priority 两态：SQL ORDER 子句与内存比较器、chip 文案 | UI |
| `ListRow.swift` | `[Record] + [Project] + 折叠/搜索状态 → [ListRow]`（主列表与 Trash 各一个 builder）；所有 row↔record 换算与拖放目标解析 | UI |
| `RowFocus.swift` | Record 消失后的焦点继承规则、Priority 升降 | — |
| `Export.swift` | JSON 导出文档（列名为键，含 Trash，不含同步元数据） | 文件选择（AppDelegate / Dialogs） |
| **Storage/** | | |
| `SQLiteDatabase.swift` | sqlite3 封装：打开、WAL、语句绑定与读取、事务 | 任何表结构知识 |
| `RecordStore.swift` | schema 迁移（v4）、Record CRUD、LIKE 搜索（`onlyConflicts` 过滤）、FTS 镜像维护、Trash、冲突对（`listConflicts` / `resolveConflict`）、导出（JSON 全量 / `VACUUM INTO`）、串行队列与事务 | UI、CloudKit |
| `RecordStore+Sync.swift` | 同步元数据信封、pending/tombstone、远端变更落库（三方合并） | CloudKit 类型 |
| `ProjectStore.swift` | Project CRUD、手动顺序、删除时把 Record 归还 Inbox | UI |
| **Sync/** | | |
| `SyncEngine.swift` | CKSyncEngine 生命周期、账号状态、本地提交 → 上传、远端事件 → 落库、状态落 `Preferences` | 合并规则 |
| `ConflictMerger.swift` | 三方合并：逐字段取新、Content 冲突保留双方（`conflictOf`） | IO |
| `CKRecordMapping.swift` | Record/Project ↔ `CKRecord` 字段映射 | — |
| `SyncTypes.swift` | 同步枚举与错误类型 | — |
| **Surfaces/** | | |
| `MainViewController.swift` | 状态（records/rows/scope/projects）、子视图装配与覆盖层布局、焦点路由（Input ↔ Row Focus）、搜索（`settledSearchGeneration`）、row↔record 映射、分组折叠、Trash surface 切换、table data source 与显式行高（`heightOfRow`） | 具体动作 |
| `MainViewController+Records.swift` | Create、Priority、Resolve、Copy、Inline Edit（键盘与双击）、Move、Move to Trash、右键菜单、冲突解决 + Undo/Redo 登记 | 布局 |
| `MainViewController+Projects.swift` | Project 列表加载（唯一入口 `reloadProjectsAndSearch`）、Scope 切换、Project 新建/重命名/删除、拖拽重排 | — |
| `MainViewController+Smoke.swift` | `--ui-smoke` 的只读探针与少量"同一路径"的驱动钩子 | 生产逻辑 |
| `TrashViewController.swift` | Trash 次级表面：列表（显式行高）、Restore、Permanent Delete、Esc/Back 返回、标题栏标题（`WindowTitleLabel`） | 撤销（复用主栈） |
| `Dialogs.swift` | 保存失败、Project 命名、删除确认、永久删除确认、导出保存面板 | 焦点 |
| **Views/** | | |
| `Theme.swift` | 唯一视觉令牌源：间距/圆角/尺寸/墨色与纸色阶梯/字体/chip 样式/光学关系（`Optical`） | 任何视图逻辑 |
| `UniversalInputView.swift` | 玻璃胶囊里的 Universal Input（占位文案、无障碍标签） | 搜索/创建逻辑（控制器） |
| `GlassCapsuleView.swift` | 26+ 用 `NSGlassEffectView`，否则 fallback 填充 | — |
| `ScopeBarView.swift` | 横向 Scope 条：chip 生成、选中、溢出渐隐、拖拽重排与 drop | Project 数据 |
| `ScopeChipButton.swift` | 自绘 chip：`.capsule` / `.filled` / `.plain` 三种样式、`iconOnly`、SF Symbol 按对齐带绘制、拖拽与 drop | — |
| `RecordTableView.swift` | Row Focus 键盘状态机（↑↓ 边界回 Input、←→/Space/Enter/⌫/⌘A/⌘C 分发）、改宽重测（推迟一轮）、`scrollRowToVisible` 避开覆盖栏、`ClearTableRowView` 选中块、`OverlayScrollView` | 业务 |
| `RecordCellView.swift` | Record 行绘制、多行换行、显式行高测量（`displayHeight` / `contentFieldWidth`）、Inline Edit 的 field editor、日期格式 | 持久化 |
| `GroupHeaderCellView.swift` | All View 分组头：标题、chevron（对齐 "+"）、折叠点击、右键 | — |
| `EdgeDissolve.swift` | 列表上下的滚动驱动渐隐遮罩 | 布局 |
| `RecordDragTypes.swift` | 拖拽 pasteboard 类型 | — |
| **Resources/** | | |
| `Assets.xcassets` | App 图标（`AppIcon.appiconset`，用户提供的 iconset）；SPM target 用 `exclude` 跳过 | — |
| **Diagnostics/** | | |
| `scripts/release.sh` + `ExportOptions.plist`（仓库根） | 分发：archive → Developer ID 导出 → 公证 → staple → zip；产物在 `build/`（gitignore） | — |
| `UISmokeRunner.swift` | `--ui-smoke` 驱动：步骤顺序、事件合成、等待/断言工具 | 生产逻辑 |
| `UISmokeRunner+Chrome.swift` | 窗口几何、Scope Bar、像素对齐、覆盖栏、光学轨（墨迹）、底栏 | — |
| `UISmokeRunner+Flows.swift` | Create → Search → Priority → Resolve → Inline Edit → Delete → Undo 链路、双击、右键、冲突、Trash、Settings、窗口重开 | — |
| `UISmokeRunner+Snapshots.swift` | `--snapshot-dir` 渲染 PNG | — |
| `RecordStore+Smoke.swift` | `#if DEBUG` 的冒烟专用写入（制造冲突对） | 生产逻辑 |
| `SyncProbeRunner.swift` | `--sync-probe` 双库端到端验证 | — |

## 4. 线程模型

- **UI 全部在主线程**。
- **数据库一条串行队列、一个连接**（`RecordStore.queue`，`ProjectStore` 共用）。每个 store 方法 `queue.async` 执行、`DispatchQueue.main.async` 回调；因此 completion 按提交顺序到达主线程，`RecordStore.batch` 的计数器不需要锁。
- 同步层在 DB 队列上订阅 `onDidCommitChange`，CloudKit 回调显式 hop 到 DB 队列落库，完成后发 `.inboxDidApplyRemoteChanges` 通知到主线程。
- 不用 actor、不开 Swift 6 严格并发（SPEC §2）。

## 5. 不变量（改动前必须知道）

1. **row↔record 只经 `ListRowIndex`**。控制器里不允许手工换算索引；列表结构改动先改 `ListRows.build` 并补单测。
2. **`searchGeneration` 是重入保护**。每次搜索递增并把 token 带回；Inline Edit 开始时也递增，这样任何迟到的搜索 completion 都不会在编辑中 `reloadData()`。
3. **焦点继承**（Resolve/删除/移出 Scope 后）：下一条 → 上一条 → 回 Input；Show Resolved 开启时只在 Open 序列上走。规则在 `RowFocusInheritance`，调用在 `inheritFocus`/`applyResolveResult`。
4. **Undo 覆盖 Resolve/Reopen、Move（改 Project）、Move to Trash**，Priority 与 Inline Edit 不在栈上；反向动作在 handler 开头**同步**注册（store 写入是异步的，在 completion 里注册会开新 undo 组）。Reopen 的 redo 会写入新的 `resolvedAt`，不是原时间戳。
5. **Project 列表变更只走 `reloadProjectsAndSearch`**：它负责 Scope 失效回退到 All、刷新 Scope Bar 与 Go 菜单、保焦点重搜。
6. **窗口顶层 surface 用 autoresizing，不用四边 Auto Layout 钉死**（否则窗口坍缩到 fitting size，见 HISTORY「窗口坍缩事故」）。内部布局仍用 Auto Layout。
7. **No Silent Data Loss**：Create 失败把文本放回 Input；Inline Edit 空提交等同取消；任何写失败都 `refreshVisibleSurface()` 从 DB 重同步，而不是修补本地状态。
8. **Scope 是搜索范围与 Create 目标的唯一来源**（`currentScope.createTargetProjectID`）。

## 6. 典型数据流

- **键入** → `controlTextDidChange` → `performSearch(term:)` → `store.search(token)` → 主线程 `records = …; rebuildRowsAndReload()`。
- **Row Focus 动作**（以 Space 为例）→ `RecordTableView` 解析按键 → `onToggleResolve(rows)` → `+Records.toggleResolve` → `RecordStore.batch(setStatus)` → 成功：本地 patch + rebuild + 焦点继承；失败：弹窗 + 从 DB 重同步。
- **远端变更** → `SyncEngine` 落库 → `.inboxDidApplyRemoteChanges` → `reloadProjectsAndSearch()`（Trash 打开时同时刷新 Trash）。

## 7. 为什么是 AppKit（2026-08 复核结论）

- **SwiftUI**：macOS 上 `List`/`Table` 的选中态与键盘焦点做不到 PRD §8 的精确语义，最终必然包 `NSViewRepresentable`，等于两套框架各付一遍成本；启动与内存也重一档。若做 iOS 端，只在那一端用 SwiftUI，复用纯逻辑/存储/同步层。
- **GPUI（Zed）**：为自绘编辑器级渲染而生；对一个几百行的列表是反向优化——Rust 工具链、FFI、Metal 管线初始化、辅助功能与 IME 自补、二进制膨胀，"轻快感"会变差。
- 结论：**留在 AppKit，持续瘦身**，UI 打磨方向是"更多用平台组件，更少自绘"（§8）。

## 8. UI 组件原则：平台原生优先

视觉语言本身（令牌、不变量、边缘溶解）在 [docs/ui.md](ui.md)；本节只登记"哪些自绘、为什么"。

规则（SPEC §9）：先找 AppKit 现成控件/样式；只有平台控件无法表达 PRD 语义**或实测更贵**时才自绘；每个自绘组件在下表登记原因，打磨阶段逐项复审。

| 现状自绘 | 为什么自绘 | 平台候选 / 复审方向 |
|---|---|---|
| `RecordTableView.scrollRowToVisible`（重写）与显式行高（`RecordCellView.displayHeight`） | 行必须落在上下两条覆盖栏之间；行高与绘制同源、按内容缓存；见 CLAUDE.md 已知坑 | 平台的自动行高与 scrollRowToVisible 在覆盖栏 + 重载场景下不可靠（实测），保留 |
| `ScopeChipButton`（`.capsule`：Scope Bar、"+"；`.filled` 圆角矩形：底栏 Resolved/Sort/Trash 为 `iconOnly` 正方形、Conflicts、Trash 动作栏；`.plain`：Trash 的 Back） | 选中态不改宽度、`refusesFirstResponder`、symbol 固定槽位、拖拽排序与 drop；**且实测比平台 accessory-bar `NSButton` 便宜**（首绘 −3…−15 ms/个、重绘 −2…−5 ms/个，按实例累加；HISTORY 性能基线） | 已评估并否决替换。保留；只需跟随系统深浅色与尺寸对齐，不追求系统 bezel 样式 |
| `GlassCapsuleView` | Liquid Glass 在 26+ 才有，需 fallback | 保留，但已是"平台组件 + fallback"形态；等最低版本升到 26 后直接用 `NSGlassEffectView` |
| `GroupHeaderCellView` + 手工折叠状态 | All View 分组折叠 | 已评估并否决 `NSOutlineView`（微基准：首绘 +8 ms、每次 reload +1.5 ms，只有折叠更快；HISTORY 性能基线）。保留；折叠手感如需提升，改 `insertRows/removeRows` 局部更新 |
| `RecordCellView` 的 Inline Edit（field editor 测量与行高） | 多行自适应编辑 | 保留；`NSTextField` 已是平台组件，自定义只在测量 |
| `ClearTableRowView.layout` + `frameOfCell` 拉宽 cell | AppKit 在 `.fullWidth` 下仍给 cell 6 pt 内缩 | 复审 2026-08-22（26.6）：仍需要；冒烟的文字轨断言即复审机制 |
| `TitlebarBackdrop.hideSystemFill` | Tahoe/27 标题栏材质盖住 sidebar 模糊 | 26.6 上为空操作，为 27 保留；冒烟断言 `visibleSystemFills` 为空，系统修复后删除 |
| 状态栏右键菜单的临时 `item.menu` | 左键开窗、右键菜单 | 保留（AppKit 无直接 API） |
| ~~硬编码 keyCode（`RecordTableView`）~~ | — | 已改为按 `specialKey` / 字符判定，键盘布局无关 |

## 9. 验证矩阵

| 改了什么 | 必跑 | 必补 |
|---|---|---|
| 纯逻辑 / 存储 / 合并 | `swift test` | 对应单测 |
| UI 行为或几何 | `--ui-smoke` | `UISmokeRunner` 断言（经 `+Smoke` 探针） |
| 键盘语义 | `--ui-smoke` | README 键盘表；不得触碰 PRD §22.2 |
| schema | `swift test` | 迁移 + `docs/SCHEMA.md` |
| 新增/删除源文件、工程配置 | `xcodegen generate` + xcodebuild | 提交 `project.yml` 与生成的 pbxproj；纯逻辑文件加入 InboxTests includes |
| 同步 | xcodebuild + `--sync-probe` 双库 | — |

## 10. 性能基线与启动路径约定

- 数字见 HISTORY「性能基线」（2026-08-22：冷启动 278 ms vs 平台底价 180 ms；发布二进制 569 KB；搜索 10k 行 ≈ 2 ms）。测量方法在 HISTORY 决策 15。
- **启动路径约定**：`applicationDidFinishLaunching` 里第一帧之前只做"打开数据库 → 建控制器 → 建窗口 → 显示"；CloudKit 引擎、状态栏项、离线检测在首帧后 0.25 s 的延迟块里启动（`--sync-probe` 除外）。新增启动工作默认放进延迟块，除非它是第一帧可见的。
- **诊断代码只在 DEBUG**：`Diagnostics/` 与 `+Smoke.swift` 整体 `#if DEBUG`；Release 里 `--ui-smoke`/`--sync-probe` 只是被解析然后忽略。
- **缓存约定**：文本测量（`WrappingTextFieldCell`）、着色 symbol（`ScopeChipButton`）、DateFormatter 都是单入口或小字典缓存，键里包含所有影响结果的输入（宽度/字符串/字号、appearance 名）；不要加带淘汰策略的缓存。
- **warm activation**（PRD §17.1）：App 自身部分中位 11 ms，冒烟每次运行都打印 `PERF warm-activation` 并以 100 ms 为门槛。
