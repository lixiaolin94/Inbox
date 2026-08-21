# Inbox

> **Inbox 是一个刻意保持小而专注的个人开发 Record 工具：通用启动器负责把用户带进来，进入之后它以 Input 为第一入口，用一套极短、稳定、可形成肌肉记忆的交互，让用户完成记录、查找、整理和解决，然后离开。**（[PRD §25](Inbox_macOS_MVP_PRD_v0.1.md)）

`v0.2.0` · macOS 14+ · MVP 本地功能完成（S1–S5） · CloudKit 记录级同步已接入（S6，CKSyncEngine）

Inbox 用一个统一的 `Record` 概念覆盖 Todo、Issue、Bug、Observation、Idea 等一切「想到就要记下来」的内容，不要求创建前判断类型。详见 [`Inbox_macOS_MVP_PRD_v0.1.md`](Inbox_macOS_MVP_PRD_v0.1.md)（产品定义）与 [`SPEC.md`](SPEC.md)（工程约定）。

## 核心特性

- **Universal Input**：单一输入框身兼 Create 与 Search；有内容时列表实时转为当前 Scope 内的相关结果，不进入独立搜索模式。
- **Enter 创建**：只要焦点没有主动移到某条 Record 上，Enter 永远是"创建当前输入内容"，即使存在完全相同的内容。
- **键盘模型**：`↑↓` 在 Input 与 Record List 间导航；`←→` 调整 Priority；`Space` Resolve / Reopen；`Enter` 进入 Inline Edit；`M` 打开 Move 菜单；`⌫` 移入 Trash；`⌘Z` 撤销删除；`⌘1…⌘0` 切换 Scope。
- **Project Scope**：横向 Scope Bar（`All | Project… | +`），All View 按 Inbox → Project Manual Order 分组并可折叠；Scope 同时决定搜索范围和新建 Record 的归属。
- **排序与 Show Resolved**：Newest First / Oldest First / Priority 三种全局排序；`Show Resolved` 关闭时 Resolved 立即从列表消失，开启时在独立分组显示。
- **Trash**：软删除 + `⌘Z` 撤销；独立 Secondary Surface 提供 Restore 和高成本、明确确认的 Permanent Delete。
- **菜单栏常驻**：关闭主窗口不退出进程，Dock / 菜单栏 / `⌘Tab` 重新激活时 Universal Input 立即获得焦点，首键不丢失；可选 Launch at Login。
- **Local-first SQLite**：每台设备一份本地 SQLite，所有高频操作先落盘、UI 立即反馈，再异步同步；无网络时功能完整可用。

## 构建与运行

Inbox 采用双通道工程形态：`project.yml` 是唯一权威工程描述，`Inbox.xcodeproj` 由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成并入库，因此 clone 后可直接用 Xcode 打开。**修改工程配置（target、依赖、签名等）必须改 `project.yml`，重新执行 `xcodegen generate` 后一并提交生成的 `.xcodeproj`，不要手改 `project.pbxproj`。**

### 方式一：Xcode

```
open Inbox.xcodeproj
```

选择 `Inbox` scheme 直接 Run（⌘R）。构建使用 Ad-hoc 签名，本地 Debug/Release 无需付费 Apple Developer 账号；CloudKit entitlements 要到 S6 才会引入。

### 方式二：Swift Package Manager

```
swift build   # 编译，产物在 .build/debug/Inbox
swift run     # 编译并启动
swift test    # 运行单元测试（存储层 + 纯逻辑，秒级完成）
```

### 方式三：UI 冒烟

```
.build/debug/Inbox --ui-smoke
```

`--ui-smoke` 会在进程内通过 `NSEvent` 合成真实键盘事件，驱动完整的 Create → Search → Priority → Resolve → Delete → Undo 链路（见 [`Sources/Inbox/UISmokeRunner.swift`](Sources/Inbox/UISmokeRunner.swift)）。该模式使用临时数据库路径和独立的 `UserDefaults` suite（`com.xiaolin.Inbox.smoke`），不会触碰真实数据；完成后打印 `UI-SMOKE PASS` 并以退出码 0 结束，失败则打印 `UI-SMOKE FAIL: …` 并以非零退出码结束。注意：中文/输入法组合无法通过合成按键事件覆盖，此冒烟只验证 ASCII 路径。

## 键盘速查表

| 位置 | 按键 | 行为 |
|---|---|---|
| Universal Input | `Enter` | 创建当前输入内容为新 Record |
| Universal Input | `↓` | 焦点移入 Record List 第一条可见结果 |
| Record List（Row Focus） | `↑` / `↓` | 在可见 Record 间导航；第一条上按 `↑` 返回 Input |
| Record List（Row Focus） | `⇧↑` / `⇧↓` | 扩展多选选区（也可 ⇧点击 / ⌘点击） |
| Record List（Row Focus） | `⌘A` | 全选当前列表的 Record |
| Record List（Row Focus） | `⌘C` | 拷贝选中 Record 的内容（多选时每条一行） |
| Record List（Row Focus） | `←` | 提高 Priority（向 P0 方向前进一档，已在 P0 不循环；作用于整个选区） |
| Record List（Row Focus） | `→` | 降低 Priority（向 P3 方向前进一档，已在 P3 不循环；作用于整个选区） |
| Record List（Row Focus） | `Space` | Toggle Resolved / Reopen（多选时：选区内有 Open 则全部 Resolve，全为 Resolved 才 Reopen） |
| Record List（Row Focus） | `Enter` | 进入 Inline Edit（`Enter` 提交 / `Esc` 取消；仅单选时有效） |
| Record List（Row Focus） | `M` | 打开 Move to（切换选中 Record 的 Project 归属） |
| Record List（Row Focus） | `⌫` (Delete/Backspace) | 移入 Trash（软删除；多选为一步操作，`⌘Z` 一次性还原） |
| Record List（All View） | 鼠标拖拽 | 拖拽选中行到某个分组，批量调整 Project 归属 |
| 全局 | `⌘Z` / `⌘⇧Z` | 撤销 / 重做 Move to Trash |
| 全局 | `⌘1` | 切到 All |
| 全局 | `⌘2`…`⌘0` | 按 Project Manual Order 切到对应 Project（第 1–9 个；更多需用 Scope Bar 或鼠标） |
| 全局 | `⌘,` | 打开 Settings（Record 字号、Launch at Login、iCloud Sync） |
| 全局 | `⌘W` | 隐藏主窗口（进程继续驻留，不是关闭应用） |
| 全局 | `⌘Q` | 退出应用 |

对应实现：[`RecordTableView.swift`](Sources/Inbox/RecordTableView.swift)（Row Focus 状态机）、[`MainViewController.swift`](Sources/Inbox/MainViewController.swift)（Input 与整体路由）、[`AppDelegate.swift`](Sources/Inbox/AppDelegate.swift)（菜单与 `⌘Number`）。

## 数据与开放性

数据库位于 `~/Library/Application Support/Inbox/inbox.sqlite`，单文件 SQLite，格式开放、可被任意 SQLite 工具、脚本或 Agent 读取。完整字段说明见 [`docs/SCHEMA.md`](docs/SCHEMA.md)。

外部工具**只读**时请使用只读连接（如 `sqlite3 'file:...?mode=ro'`）或先复制副本，不要在 Inbox 运行期间对活动数据库直接写入——第三方直接写库不是稳定接口，会绕过校验、迁移和未来的同步/冲突逻辑（[PRD §16.2](Inbox_macOS_MVP_PRD_v0.1.md)）。

## 性能

在 10,000 条 Record 的本地实测中（Release 配置，`RecordStore.search`，见交付说明中的测量方法）：

- 英文子串搜索（命中约 1,000/10,000 行）：约 2ms；
- 中文子串搜索，含 1–2 字短查询：约 2ms；
- 无过滤条件的全量列出 / 按 Priority 排序（10,000 行全返回）：约 5ms。

均远低于 [PRD §17.3](Inbox_macOS_MVP_PRD_v0.1.md) 规定的 50ms/10,000 行预算。搜索使用绑定参数的 `content LIKE '%term%'` 扫描而非 FTS5 MATCH，原因见 [`RecordStore.swift`](Sources/Inbox/RecordStore.swift) 顶部注释与下文 SCHEMA 文档。

## 路线图现状

对照 [PRD §20](Inbox_macOS_MVP_PRD_v0.1.md)：

- **Phase 0（技术验证）/ Phase 1（macOS MVP 本地闭环）**：已完成。Universal Input、Scope Bar、Record List 键盘模型、排序、Show Resolved、Trash/Undo、菜单栏驻留、Launch at Login、UI 冒烟均已合并 main（S1–S5）。
- **CloudKit 同步（S6）**：已完成。CKSyncEngine + 私有库自定义 zone `InboxZone`，容器 `iCloud.com.xiaolin.Inbox`（当前 Development 环境）。schema v3 引入 `ck_system_fields`（system fields + 共同祖先字段快照）、`pending_change`、`tombstone`，冲突按无损原则做字段级三方合并（详见 [`docs/SCHEMA.md`](docs/SCHEMA.md)）。双库端到端验证：`--sync-probe create/expect` 配合 `--db-path` 可在单机模拟双设备。上架/分发前需将容器环境切至 Production 并部署 schema。
- **之后**：Phase 2 打磨与开放能力（导出、诊断、Accessibility）、Phase 3 Attachment、Phase 4+ iOS。

## 工程协作说明

本项目由多模型流水线开发：Fable 担任协调者，负责拆分任务、审阅代码与合并决策；Grok 4.6（xhigh reasoning effort）承担主力编码；Claude Sonnet 在需要时顶替编码或处理机械性杂务。协作规则、Slice 划分和验收标准见 [`SPEC.md`](SPEC.md)。
