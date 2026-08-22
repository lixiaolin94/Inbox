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
App/          main · AppDelegate · LaunchConfiguration · Preferences · SettingsViewController
Surfaces/     MainViewController(+Records/+Projects/+Smoke) · TrashViewController · Dialogs
Views/        UniversalInputView · ScopeBarView · ScopeChipButton · RecordTableView · RecordCellView
              GroupHeaderCellView · GlassCapsuleView · RecordDragTypes
Model/        Record · Project · Scope · ListRow · RowFocus · RecordSort · Export
Storage/      SQLiteDatabase · RecordStore · RecordStore+Sync · ProjectStore
Sync/         SyncEngine · SyncTypes · CKRecordMapping · ConflictMerger
Diagnostics/  UISmokeRunner · SyncProbeRunner
```

依赖方向自上而下；`Model/`、`Storage/`、`Sync/` 的纯逻辑文件不 import AppKit，因此能进 `swift test`（`project.yml` 的 InboxTests target 按目录路径逐文件列出了这些源文件——新增纯逻辑文件要同步加进去）。新文件放进它所属的层；一个文件跨两层说明职责没切干净。

## 3. 文件职责速查

| 文件 | 负责 | 不负责 |
|---|---|---|
| `AppDelegate.swift` | 窗口创建与尺寸约束、主菜单（App/File/Edit/Go）、File 导出入口（JSON / 快照 / Finder 定位）、`⌘Number`、状态栏项、Undo/Redo 路由（field editor 优先于 Move-to-Trash 栈）、Settings 窗口 | 任何 Record/Project 业务 |
| `MainViewController.swift` | 状态（records/rows/scope/projects）、子视图装配与布局、焦点路由（Input ↔ Row Focus）、搜索、row↔record 映射、分组折叠、Trash surface 切换、table data source | 具体动作 |
| `MainViewController+Records.swift` | Create、Priority、Resolve、Copy、Inline Edit、Move、Move to Trash + Undo/Redo | 布局、Project 列表 |
| `MainViewController+Projects.swift` | Project 列表加载（唯一入口 `reloadProjectsAndSearch`）、Scope 切换与持久化、Project 新建/改名/删除/排序、All View 拖拽改 Project | Record 动作 |
| `MainViewController+Smoke.swift` | `--ui-smoke` 的只读探针 | 生产逻辑 |
| `TrashViewController.swift` | Trash 次级表面：列表、Restore、Permanent Delete、Esc 返回 | 撤销（复用父控制器的 UndoManager） |
| `RecordTableView.swift` | Row Focus 键盘状态机（↑↓ 边界回 Input、←→/Space/Enter/⌫/⌘A/⌘C 分发、右键选区语义；Move 无快捷键） | 数据 |
| `RecordCellView.swift` | Record 行绘制、多行换行、Inline Edit 的 field editor 与行高自适应 | 持久化 |
| `ScopeBarView.swift` / `ScopeChipButton.swift` | 横向 Scope 条、chip 样式与拖拽排序、`LayoutChrome` 常量 | — |
| `Dialogs.swift` | 保存失败、Project 命名、删除确认、永久删除确认、导出保存面板 | 焦点（由调用方决定） |
| `Preferences.swift` | UserDefaults suite 切换；lastScope / collapsedGroups / sortOrder / showResolved / syncEnabled / lastSync{SucceededAt,Error,ErrorAt} 的类型化访问器；`.inboxAppearanceDidChange` / `.inboxSyncStatusDidChange` 通知名；字号与行高常量 | — |
| `ListRow.swift` | `[Record] + [Project] + 折叠/搜索状态 → [ListRow]`；所有 row↔record 换算 | UI |
| `RowFocus.swift` | Record 消失后的焦点继承规则 | — |
| `RecordStore.swift` | schema 迁移（v4）、Record CRUD、LIKE 搜索（`onlyConflicts` 过滤）、FTS 镜像维护、`batch` 扇出、导出读取与 `VACUUM INTO` 快照、冲突对（`listConflicts` / `resolveConflict`，无损） | Project（在 `ProjectStore`） |
| `Model/Export.swift` | JSON 导出文档（列名为键，含 Trash，不含同步元数据） | 文件选择（AppDelegate / Dialogs） |
| `Diagnostics/RecordStore+Smoke.swift` | `#if DEBUG` 的冒烟专用写入（制造冲突对） | 生产逻辑 |
| `RecordStore+Sync.swift` | 同步元数据信封、pending/tombstone、远端变更落库 | CloudKit 类型 |
| `SyncEngine.swift` | CKSyncEngine 生命周期、账号状态、本地提交 → 上传、远端事件 → 落库 | 冲突规则（在 `ConflictMerger`） |

## 4. 线程模型

- **UI 全部在主线程**。
- **数据库一条串行队列、一个连接**（`RecordStore.queue`，`ProjectStore` 共用）。每个 store 方法 `queue.async` 执行、`DispatchQueue.main.async` 回调；因此 completion 按提交顺序到达主线程，`RecordStore.batch` 的计数器不需要锁。
- 同步层在 DB 队列上订阅 `onDidCommitChange`，CloudKit 回调显式 hop 到 DB 队列落库，完成后发 `.inboxDidApplyRemoteChanges` 通知到主线程。
- 不用 actor、不开 Swift 6 严格并发（SPEC §2）。

## 5. 不变量（改动前必须知道）

1. **row↔record 只经 `ListRowIndex`**。控制器里不允许手工换算索引；列表结构改动先改 `ListRows.build` 并补单测。
2. **`searchGeneration` 是重入保护**。每次搜索递增并把 token 带回；Inline Edit 开始时也递增，这样任何迟到的搜索 completion 都不会在编辑中 `reloadData()`。
3. **焦点继承**（Resolve/删除/移出 Scope 后）：下一条 → 上一条 → 回 Input；Show Resolved 开启时只在 Open 序列上走。规则在 `RowFocusInheritance`，调用在 `inheritFocus`/`applyResolveResult`。
4. **Undo 覆盖 Resolve/Reopen、Move（改 Project）、Move to Trash**（R12），Priority 与 Inline Edit 不在栈上；反向动作在 handler 开头**同步**注册（store 写入是异步的，在 completion 里注册会开新 undo 组）。Reopen 的 redo 会写入新的 `resolvedAt`，不是原时间戳。
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

规则（SPEC §9）：先找 AppKit 现成控件/样式；只有平台控件无法表达 PRD 语义**或实测更贵**时才自绘；每个自绘组件在下表登记原因，打磨阶段逐项复审。R7 的教训：系统 bezel 的绘制路径（CoreUI 素材 + 玻璃材质）比一个 CALayer 边框长得多，"平台组件 = 更快"对轻量自绘不成立——换之前先用微基准量（方法在 HISTORY 决策 10）。

| 现状自绘 | 为什么自绘 | 平台候选 / 复审方向 |
|---|---|---|
| `ScopeChipButton`（胶囊 chip：Scope Bar、"+"、底栏 Resolved/Sort/Trash、Trash 动作栏） | 选中态不改宽度、`refusesFirstResponder`、symbol 固定槽位、拖拽排序与 drop；**且实测比平台 accessory-bar `NSButton` 便宜**（首绘 −3…−15 ms/个、重绘 −2…−5 ms/个，按实例累加；HISTORY 性能基线 R7） | 已评估并否决替换（R7）。保留；只需跟随系统深浅色与尺寸对齐，不追求系统 bezel 样式 |
| `GlassCapsuleView` | Liquid Glass 在 26+ 才有，需 fallback | 保留，但已是"平台组件 + fallback"形态；等最低版本升到 26 后直接用 `NSGlassEffectView` |
| `GroupHeaderCellView` + 手工折叠状态 | All View 分组折叠 | 已评估并否决 `NSOutlineView`（R8 微基准：首绘 +8 ms、每次 reload +1.5 ms，只有折叠更快）。保留；折叠手感如需提升，改 `insertRows/removeRows` 局部更新 |
| `RecordCellView` 的 Inline Edit（field editor 测量与行高） | 多行自适应编辑 | 保留；`NSTextField` 已是平台组件，自定义只在测量 |
| `ClearTableRowView.layout` + `frameOfCell` 拉宽 cell | AppKit 在 `.fullWidth` 下仍给 cell 6 pt 内缩 | 复审 2026-08-22（26.6）：仍需要；冒烟的文字轨断言即复审机制 |
| `TitlebarBackdrop.hideSystemFill` | Tahoe/27 标题栏材质盖住 sidebar 模糊 | 26.6 上为空操作，为 27 保留；冒烟断言 `visibleSystemFills` 为空，系统修复后删除 |
| 状态栏右键菜单的临时 `item.menu` | 左键开窗、右键菜单 | 保留（AppKit 无直接 API） |
| ~~硬编码 keyCode（`RecordTableView`）~~ | — | 已改为按 `specialKey` / 字符判定（R7），`M` 在任何布局可用 |

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

- 数字见 HISTORY「性能基线」（2026-08-22：冷启动 278 ms vs 平台底价 180 ms；发布二进制 569 KB；搜索 10k 行 ≈ 2 ms）。测量方法在 HISTORY 决策 10。
- **启动路径约定**：`applicationDidFinishLaunching` 里第一帧之前只做"打开数据库 → 建控制器 → 建窗口 → 显示"；CloudKit 引擎、状态栏项、离线检测在首帧后 0.25 s 的延迟块里启动（`--sync-probe` 除外）。新增启动工作默认放进延迟块，除非它是第一帧可见的。
- **诊断代码只在 DEBUG**：`Diagnostics/` 与 `+Smoke.swift` 整体 `#if DEBUG`；Release 里 `--ui-smoke`/`--sync-probe` 只是被解析然后忽略。
- **缓存约定**：文本测量（`WrappingTextFieldCell`）、着色 symbol（`ScopeChipButton`）、DateFormatter 都是单入口或小字典缓存，键里包含所有影响结果的输入（宽度/字符串/字号、appearance 名）；不要加带淘汰策略的缓存。
- **warm activation**（PRD §17.1）：App 自身部分中位 11 ms，冒烟每次运行都打印 `PERF warm-activation` 并以 100 ms 为门槛。
