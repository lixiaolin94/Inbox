# R2 测试审查任务书（审查模型专用）

你是独立测试审查员。工作目录即仓库根。**只报告，不改 `Sources/`**；
`Tests/` 目录是你的产出区，可以新增测试文件。不 commit。

## 背景材料（先读）

- `docs/design/r2-immersive-sync-multiline.md`（设计，判定依据）
- `docs/prompts/r2.md`（执行任务书，白名单依据）
- `CLAUDE.md`、`SPEC.md` §3/§4/§8（质量与测试红线：测试只覆盖存储层/纯逻辑/冲突合并，不写 UI 自动化——UI 由 `--ui-smoke` 覆盖）

## 审查项

### 1. 构建与既有门槛

```bash
swift build          # 必须零错
swift test           # 必须全绿
.build/debug/Inbox --ui-smoke   # 期望 UI-SMOKE PASS；若你的沙箱无窗口服务导致失败，原样记录错误并标注"需主 Agent 补跑"
```

### 2. 静态审查（逐条给结论）

- `git diff --stat` 对照任务书白名单：不得出现 docs/、project.yml、pbxproj、schema、ListRow.swift、RecordStore*.swift；SyncEngine.swift 只允许 shouldEnable 相关最小改动。
- 窗口坍缩风险（HISTORY 决策 6）：检查 RecordCellView 新约束与 usesAutomaticRowHeights 组合——content 的水平压缩阻力必须仍为 defaultLow；不得出现把 tableView/scrollView 固有尺寸传导到窗口的新约束；MainViewController 顶层 autoresizing 布局未被触碰。
- Trash 表回归：TrashViewController 不得被开启 automaticRowHeights；RecordCellView 的新约束在固定 28pt 行高下不应打约束冲突日志（读代码推断 + 如可运行则观察 stderr）。
- 键盘语义零变化：RecordTableView.swift 的 keyDown 分支与上一版语义一致（可 git diff 核对）。
- D 段逻辑：`com.inbox.syncEnabled` 缺省 true 的读法是否正确（bool(forKey:) 缺省 false 是常见错误——必须用 object(forKey:) == nil 判缺省或 register(defaults:)）；开关关闭时不得再查 accountStatus / 不得显示离线标签；ui-smoke 路径不受影响。
- E 段：pasteboard 类型常量确实两处共用（无字符串重复字面量散落）；All/"+" chip 未注册拖放；chip 拖放与 chip 排序拖拽（自绘 mouseDown 路径）无事件竞争的明显缺陷。
- Inline Edit 与多行 cell：beginEditing 后 field editor 是否仍能正常提交/取消（读代码推断，标注风险点即可）。

### 3. 单元测试（如有可测纯逻辑）

本轮改动多为 UI，按 SPEC 不写 UI 自动化。仅当你发现可提取的纯逻辑
（例如 sync 开关判定函数）且已存在为纯函数时，用 XCTest 在 `Tests/InboxTests/`
补测；否则明确写"无新增纯逻辑可测"。禁止为测而测。

## 报告格式（stdout 末尾，标题 `## 审查报告`）

按严重度分级：**阻断 / 一般 / 建议**。每条附 `文件:行号`、问题描述、修复建议。
最后给一行总判定：`PASS` / `PASS-with-issues` / `BLOCKED`。
