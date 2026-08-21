# UI 迭代常备护栏（grok 直接对话专用）

> 用法：用户直接和 grok 对话做 UI 小步打磨时，每次会话开头让 grok 先读本文件
> （`grok --cwd <repo>` 后第一句："先读 docs/prompts/ui-iteration-guardrails.md 并遵守"）。
> 本文件替代逐轮任务书，把守则固定下来；大改动仍走 team-mode 流水线。

## 开工前必读（缺一不可）

1. `CLAUDE.md` —— 命令速查与工程铁律
2. `docs/HISTORY.md` 「关键技术决策」第 6 条 —— 窗口坍缩事故：顶层 surface 必须
   autoresizing，禁止四边 Auto Layout 钉 content view；改任何几何前先看这条
3. 要改的文件本身 + 它的调用方

## 硬性禁区

- 不 commit（用户或协调者验收后才 commit）
- 不改：`docs/`、`project.yml`、`.pbxproj`、schema、`RecordStore*.swift`、
  `SyncEngine.swift`、键盘语义（PRD §22.2 红线：`↑↓/←→/Enter/Space/⌘Number`）
- 不加依赖；不引入 storyboard/xib；Swift 5 语言模式
- 新增源文件后必须提醒用户："需要跑 `xcodegen generate`（协调者/用户做）"

## 每轮改完的自查（必须执行并贴结果）

```bash
swift build                        # 零错零警告
swift test                         # 全绿
.build/debug/Inbox --ui-smoke      # 必须打印 UI-SMOKE PASS
```

任何一项不过，先修再交，不许"先看效果"。

## UI 改动的同步义务（改了就欠账）

- 改了行为/几何 → 在 `UISmokeRunner.swift` 加对应断言（参考现有 step 写法）
- 改了键盘 → 停下，这是红线，让用户找协调者
- 语境敏感值要三查：颜色必须用语义色（`labelColor`/`secondaryLabelColor`…，
  禁止硬编码 RGB，深浅色模式都要成立）、坐标系（AppKit y 轴向上）、
  明暗双值（历史事故：黑底配了黑描边）

## 本项目 UI 现状速查

- 列表：`RecordTableView`（NSTableView 子类）+ `RecordCellView`，view-based 单列，
  `usesAutomaticRowHeights`（主表）多行换行，Priority/时间与首行基线对齐；
  Trash 表固定 28pt 单行，共用 cell 按 style 切换——改 cell 两边都要想
- 斑马纹是显式关闭的（`usesAlternatingRowBackgroundColors = false`，设计取向扁平）
- 窗口：无标题沉浸（titleVisibility hidden + 透明标题栏），content 尺寸断言在 smoke 里
- Utility bar 在 480pt 最小宽度下已经偏挤，往里加东西前先想溢出
