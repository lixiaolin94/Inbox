# 开发史与遗留事项

> 维护规则：合并 main 时在「里程碑」补一行（小修并入所在里程碑的描述）；关键决策与遗留事项随时增删，做完的直接删，不留打勾项。接手小任务前先扫「遗留事项」。

## 里程碑（2026-08-20 起）

| 里程碑 | 内容 | 提交 |
|---|---|---|
| v0.2.0 MVP 本地闭环 + 同步 | 窗口 + Universal Input + 列表 + SQLite/FTS；键盘模型（←→ Priority、Space Resolve、Enter Inline Edit、焦点继承）；Scope Bar、Project 管理、All View 分组折叠；排序与 Show Resolved；Trash 与 ⌘Z；xcodegen 工程、驻留/菜单栏/Launch at Login、`--ui-smoke`；CKSyncEngine 同步（schema v3、无损冲突合并、`--sync-probe`） | `a803517` `8e1a525` |
| 多选与沉浸表面 | 多选与批量操作、⌘C、拖拽改 Project；无标题沉浸窗口、全窗 sidebar 材质、玻璃胶囊 Input、多行换行、Settings 窗口、窗口坍缩修复 | `7627841` |
| 瘦身与启动路径 | 控制器按关注点拆 extension、`Dialogs`/`Preferences`/`RecordStore.batch` 收口、源文件按层分目录；同步引擎与状态栏项推迟到首帧后、诊断代码 `#if DEBUG`、Release arm64 + `-Osize`、WAL | `3cad00b` |
| 发布准备 | 键盘按字符判定；底栏换平台按钮实验（否决，见基线）；CloudKit 环境按配置、File 导出、同步状态、搜索规模复查（保留 LIKE）、像素快照、冲突中心（schema v4 `conflict_of`） | `24a15fb` |
| 视觉语言 | `Theme.swift` 单一令牌源、墨色/纸色阶梯、安静选中块、透明覆盖栏 + 边缘溶解、overlay 滚动条；⌘Z 覆盖 Resolve/Move；排序两态切换；去掉 `M` 键 | `ee49489` |
| 表面与行高 | 底栏图标按钮、Trash 表面与主表面同构、`windowInset`/`contentInset` 分离并定 12；显式行高（根治自动行高的滚动跳行/只长不缩/改宽丢选区）、`scrollRowToVisible` 避开覆盖栏 | `8350d3c` |
| 光学对齐与收口 | 光学轨按渲染墨迹断言（`Theme.Optical` + `stepOpticalRails`）、SF Symbol 按对齐带绘制、双击编辑、右键 Mark as Resolved、日期跟随 UI 语言、Settings 标题、发布前清扫（死代码、注释、冒烟拆文件）、App 图标接入 | HEAD |

## 关键技术决策

1. **中文搜索用 LIKE 而非 FTS5 MATCH**：unicode61 不切分 CJK；trigram 要求查询 ≥3 码点，排除 1–2 字中文词。`record_fts`（trigram）镜像仍维护，为大数据量切换预留；100k 行 LIKE p95 ≤ 40 ms（见基线）。
2. **ListRow / ListRowIndex 是唯一的表行↔Record 映射层**：分组、Resolved 小节、导航跳过非 Record 行、焦点继承全部走它；列表结构改动先改这个纯函数层并补测试。
3. **焦点继承**（Resolve/删除后）：下一条可见 → 上一条 → 回 Input；Show Resolved 开启时只在 Open 序列上走。纯函数在 RowFocus.swift。
4. **Undo 覆盖 Resolve/Reopen、Move、Move to Trash**：窗口级 UndoManager 由 AppDelegate 路由（field editor 优先）；`groupsByEvent = false`，每个动作自开 undo 组（事件分组在异步 completion + 嵌套 run loop 下会把两步并成一步）；反向动作在 handler 开头同步注册。
5. **同步元数据信封含"共同祖先"**：`ck_system_fields` 存 system fields + 上次同步的字段快照，用于区分"两端改了不同字段"（自动合并）与"同字段冲突"（无损保留双方）。规则见 ConflictMerger.swift 与 docs/SCHEMA.md。
6. **窗口坍缩教训**：顶层 surface 四边用 Auto Layout 钉在 content view 上会让 NSWindow 吸附 fitting size 坍缩到 28pt。现方案：顶层 autoresizing + 挂载后 setContentSize + `constrainFrameRect` 套 minSize；冒烟有窗口几何断言。
7. **xcodeproj 入库、project.yml 唯一权威**：Xcode 界面里点的设置必须回填 project.yml 再 `xcodegen generate`；增删 Swift 文件要重新生成。
8. **留在 AppKit**（2026-08-22 复核）：键盘语义与启动体积是产品核心；打磨方向是少自绘、多平台组件，但**换之前要量**——轻量自绘 chip 实测比平台 bezel 按钮便宜（见基线）。理由与对比见 ARCHITECTURE §7–§8。
9. **控制器按关注点拆 extension 而不是抽层**：同一个 `self`，零间接层，拆分只为导航与审阅范围；弹窗进 `Dialogs`、键进 `Preferences`、扇出进 `RecordStore.batch`。
10. **显式行高**：两张表都不用 `usesAutomaticRowHeights`——它在 `reloadData()` 时把行高重置为估算值再逐行实测，滚动偏移被夹住；`noteHeightOfRows` 只长不缩。行高由 `RecordCellView.displayHeight` 用与绘制同一套 `cellSize` 测量并缓存。
11. **光学对齐按墨迹裁判**：左右两条轨的关系（日期/chevron/"+"/All/P）写在 `Theme.Optical`，冒烟渲染位图扫描字形边缘断言；令牌（nudge）是手段，墨迹是裁判。
12. **内存口径**：Activity Monitor「Memory」= `phys_footprint`（`footprint -p <pid>`），不是 RSS。Inbox Release 25 MB（最小 AppKit 窗口 17 MB）。
13. **视觉语言来源**：tinycast 的 `docs/ui.md` + `Theme.swift` 写法（一段话、一条阶梯、令牌单源、不可变项、溶解参数）；没有采纳它的无边框面板形态与快捷键提示。
14. **性能测量方法**：启动用"spawn → 首个 layer-0 窗口出现"计时（轮询 `CGWindowListCopyWindowInfo`），对照最小 AppKit 窗口程序作底价；体积看 `strip -x` 后单架构二进制；剖析用 xctrace Time Profiler——`--launch` 按 bundle id 经 LaunchServices 取包，会拿到 DerivedData 的旧 Debug 包，要复制 Release 包改 CFBundleIdentifier 并 `codesign --force --deep --sign -`。控件微基准：单独冷进程、上屏 layer 路径、N=1 与 N=10、交替 A/B。

## 性能基线（Release，Apple Silicon，2026-08-22；方法见决策 14）

| 指标 | 最小 AppKit 窗口 | Inbox |
|---|---|---|
| spawn → 出窗 中位数 | 180–186 ms | 278 ms（.app）/ 245 ms（裸） |
| phys_footprint | 17 MB | 25 MB（12 线程） |
| 发布二进制（strip 后） | — | 569 KB（arm64，`-Osize`） |
| 单条写事务 | — | 0.05 ms（WAL） |
| warm 激活（`presentMainWindow` → 光标在 Input） | — | 中位 11 ms（冒烟门槛 100 ms） |

超出底价的 ~65–100 ms：`NSWindow` 创建 26 ms（macOS 26 标题栏材质，底价程序同样要付）、`MainViewController` 构建 23 ms（5 个 chip ≈ 2 ms/个）、首次布局与 field editor ~10 ms、菜单/状态栏杂项。

**底栏换平台按钮（否决）**：Utility 栏与 Trash 动作栏换 `NSButton`（accessoryBar / `NSPopUpButton`），三轮交替 A/B 冷启动 +10 ms（懒建菜单后仍 +3–5 ms）；控件微基准里系统 bezel 首绘比自绘 chip 贵 3–15 ms/个、重绘贵 2–5 ms/个，按实例累加。

**`NSOutlineView`（否决）**：首绘 30 vs 38 ms、warm reload 9.4 vs 11.0 ms、滚动 4.0 vs 4.9 ms；只有折叠一组更快（9.4 vs 1.5 ms）——赢的是低频操作，输的是热路径。

**搜索规模**（中英各半语料，p50 / p95 ms，`store.search` 端到端）：

| N | 英文常见词 | 英文罕见词 | 中文 1 字 | 中文 2 字 | 中文 5 字 | 空词（全量） |
|---|---|---|---|---|---|---|
| 10k | 2.5 / 2.8 | 1.8 / 1.9 | 2.9 / 3.1 | 2.7 / 2.9 | 2.1 / 2.3 | 7.2 / 7.4 |
| 50k | 14.9 / 15.0 | 11.2 / 11.4 | 17.2 / 17.6 | 15.9 / 16.1 | 13.0 / 13.5 | 38.7 / 39.1 |
| 100k | 32.7 / 33.5 | 24.9 / 25.2 | 36.8 / 37.2 | 34.3 / 35.0 | 28.6 / 29.2 | 80.0 / 81.1 |

LIKE 约 2.5 µs/行与命中数无关；FTS5 MATCH 只在低命中词上赢，且不能服务 1–2 字中文查询。保留 LIKE。

## 遗留事项

### 发布前必须（用户）

- CloudKit Console 把 Development schema 部署到 Production（Record/Project 两个 Record Type 及索引，含 `Record.conflictOf`）；entitlements 已按配置取值（Release = Production）。
- 选分发方式（Developer ID 公证 / App Store）并归档。
- /Applications 形态下人工确认 Launch at Login；用 Release 包跑一次 `--sync-probe`；清理开发容器里的探针记录（App 内 ⌫）。
- 深色模式下 Universal Input 的玻璃在快照里是纯白平面（`NSGlassEffectView` 由窗口服务器合成，离屏快照画不出来），上屏确认一次。

### 已知小缺陷

- Inline Edit 提交遇 DB 写入失败时编辑文本随弹窗丢弃（应保留编辑态让用户重试/复制）。
- Trash 分组组头画了 chevron 但不可折叠（PRD 对 Trash 无折叠要求）。
- 已删除 Project 的折叠状态键残留在 UserDefaults（无害）。
- All View 拖拽改 Project 无自动化覆盖（冒烟不合成拖拽），依赖人工；drop 目标解析有单测。
- iCloud 账号状态只在启动时检测一次；iCloud Sync 开关改动需重启生效（CKSyncEngine 无 stop API）。
- `record_fts` 镜像占库文件约 42% 却不在查询路径上，可考虑移除以省体积。
- `GlassCapsuleView.fallbackFill`（macOS 26 以下）仍用系统 `quaternaryLabelColor`，不在墨色阶梯上，本机无法验证。

### 产品待定（需要用户拍板）

- 冲突中心交互：Keep This / Keep Other 把放弃方移入 Trash 而非永久删除；解决不进 ⌘Z 栈；"N conflicts" chip 是会话态过滤；Conflict 标记占时间列位置。PRD §15.3 允许"弱化 Badge 或 Conflict Center"，这里选了前者。
- 导出 JSON 顶层键用 snake_case（与列名一致）。
- All View 中 Resolve 后的"下一条 Open"会跨 Project Group 边界继承焦点。
- 从 All View 空白处右键 Create Project（PRD §7.5）未实现，只有 Scope Bar 的 `+`。
- 新建 Project 后不自动切换到该 Scope。
- 切换 iCloud 账号时本地库不隔离。
