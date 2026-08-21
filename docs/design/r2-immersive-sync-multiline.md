# R2 小版本设计：沉浸窗口 / iCloud 开关与离线提示 / 列表多行 / 输入单行 / 拖拽到 Scope Bar

> 2026-08-21，协调者：Fable。五项需求来自用户原话，决策已按"简化一点"原则拍板；
> 待定项无——以下全部按本文执行。

## A. 输入框超长文本保持单行（fix）

现状：`inputField`（MainViewController）未设 single-line mode，超长文本依赖
field editor 默认行为，存在换行/撑高布局的风险。

方案：`usesSingleLineMode = true` + cell `wraps = false` + `isScrollable = true` +
`lineBreakMode = .byClipping`。效果即 macOS 标准单行编辑：文本超宽时向前顶、
光标保持可见（聚焦尾部）。不改任何布局约束。

## B. 列表 Record 多行显示，Priority/时间与首行顶对齐

现状：`RecordCellView` 所有子视图 centerY 对齐，content 单行 `byTruncatingTail`；
行高固定 28pt（`heightOfRow`）。

方案：
- `contentField.lineBreakMode = .byWordWrapping`、`maximumNumberOfLines = 0`、
  cell `wraps = true`；`setContentCompressionResistancePriority(.defaultLow, for: .horizontal)`
  保持（不得让内容把窗口顶宽——见 HISTORY 窗口坍缩事故）。
- 约束改为：`contentField` top/bottom 钉住 cell（top 6 / bottom ≥6），
  `priorityLabel.firstBaselineAnchor == contentField.firstBaselineAnchor`，
  `timeLabel.firstBaselineAnchor == contentField.firstBaselineAnchor`（顶对齐 = 与第一行基线平齐）。
- 行高：主表 `usesAutomaticRowHeights = true`，删除 `heightOfRow` 委托方法整个实现
  （group header / resolved header cell 需要自带高度约束：24 / 22；record 行加
  `heightAnchor >= 28` 于 cell 内容，保证单行行高与现在一致）。
- Trash 表保持现状（固定行高、单行截断）不动——本条只针对主列表。
  注意 RecordCellView 是两个表共用的：多行约束在 cell 内实现，但 Trash 的
  tableView 不开 automaticRowHeights，行高仍 28 截断即可（cell 在受限高度下
  clip，视觉与现状一致）。
- Inline Edit 在多行 cell 上仍进入编辑态；编辑期间的换行行为按 AppKit 默认，
  不额外处理（Enter 提交语义不变，PRD 红线）。

## C. 沉浸感窗口（去掉明显的 "Inbox" 标题）

方案（低风险，不引入 fullSizeContentView 重排版）：
- `window.titleVisibility = .hidden` + `window.titlebarAppearsTransparent = true`
- `window.isMovableByWindowBackground = true`
- `window.title = "Inbox"` 保留（Dock / ⌘Tab / 辅助功能仍需要名字）。
- 不加 `.fullSizeContentView`（会让 input 与交通灯重叠，需要重新排顶部，收益小）。
- ui-smoke：加断言 `titleVisibility == .hidden` 且 contentSize 断言全部保持通过。

## D. iCloud 同步开关 + 账号不可用降级提示

现状：`InboxSyncEngine.shouldEnable` 只看 entitlement / smoke；无用户开关；
账号未登录时 CKSyncEngine 静默不同步。

方案（无设置窗口，最简形态）：
- UserDefaults 键 `com.inbox.syncEnabled`，默认 true（`Preferences.store`，
  register 默认值或读取时 `object(forKey:) == nil` 视为 true）。
- `shouldEnable` 增加一条：该键为 false → 不启用。
- App 菜单（AppDelegate `buildAppMenu`）加 "iCloud Sync" checkbox 菜单项：
  `validateMenuItem` 里 state = 开关值；无 entitlement（SPM 裸二进制）时禁用。
  toggle 后写 defaults 并弹一次 NSAlert："更改将在下次启动 Inbox 时生效"
  （CKSyncEngine 无 stop API，即时启停不做——简化）。
- 离线提示：engine 启用后异步查 `accountStatus()`；结果非 `.available` 时，
  在 utility bar 的 Trash 按钮左侧显示一个小标签 "iCloud 不可用 · 仅离线"
  （11pt, secondaryLabelColor，默认隐藏）。不弹启动 alert（每次启动都弹会烦）。
  开关关闭 / entitlement 缺失（预期离线）时不显示该标签。
- MainViewController 暴露 `func showOfflineNotice(_ visible: Bool)`；AppDelegate
  在查询回调（主线程）里调用。

## E. All View 拖拽 Record 到 Scope Bar chip

上一轮已支持 All 内拖行到另一分组（含 Inbox↔Project）。本轮补拖放目标：
- Scope Bar 的 Project chip 接受 record 拖放（pasteboard 类型复用
  `MainViewController.recordIDPasteboardType`，需把该常量提为 internal，如挪到
  独立文件或改 `static let` 于共享处——最简：改成 `enum RecordDragTypes` 新
  小文件，两处引用）。
- `ScopeChipButton` 实现 `NSDraggingDestination`（registerForDraggedTypes），
  拖入高亮（复用选中态描边即可），放手回调 `ScopeBarView.onDropRecords?(ids, projectID)`
  → MainViewController.moveRecords(ids:to:)。
- All chip、"+" chip 不是拖放目标（拖到 All 无语义）。仅当前 Scope 为 All 时
  才有拖拽源，无需在 chip 侧限制。
- Scope Bar chip 拖放与 chip 自身的拖拽排序互不干扰（排序是 chip 自绘 mouse
  drag，不走 NSDragging）。

## 边界与不变量

- PRD 红线全部不动：键盘语义、Input→Scope→List 结构、Enter 创建等。
- 顶层 surface 仍用 autoresizing（禁止四边 Auto Layout 钉 content view）。
- 零第三方依赖；不改 schema；不改 project.yml。
- UI 行为变化 → UISmokeRunner 同步加断言（B/C/D 各一组；E 拖拽无法合成鼠标，
  沿用上轮遗留记录：靠人工冒烟 + chip drop 回调的直接调用断言可选）。
