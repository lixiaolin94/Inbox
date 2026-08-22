# Inbox — Agent 上手指南

Inbox 是 Swift + AppKit 的 macOS 个人 Record 管理工具（Keyboard-first、Local-first、CloudKit 同步），目标是比通用启动器更轻、更快、更专注。本文件是任何 Agent 在任何设备上开工前的入口。

## 读文档的顺序

1. 本文件（约定与命令速查）；
2. [SPEC.md](SPEC.md) —— 工程守则：质量红线、测试策略、Git 工作流、UI 组件原则；
3. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 分层、文件职责、线程模型、不变量、验证矩阵（**改代码前先定位到文件**）；
4. [Inbox_macOS_MVP_PRD_v0.1.md](Inbox_macOS_MVP_PRD_v0.1.md) —— 产品语义的唯一权威（改交互前必读相关章节）；
5. [docs/HISTORY.md](docs/HISTORY.md) —— 已做过什么、为什么这么做、遗留事项（**接小任务先查这里的清单**）；
6. [docs/SCHEMA.md](docs/SCHEMA.md) —— 数据库结构（改存储前必读）；
7. [docs/ui.md](docs/ui.md) —— 视觉语言：墨色阶梯、圆角/间距/字号令牌、不可变项、边缘溶解原理（**改任何视图或 `Theme` 值前必读**）。

`docs/design/`、`docs/prompts/` 是历史迭代的设计稿与派发提示词，只作考古，不是现行约定。

## 产品红线（PRD §22.2，不得未经用户评审改变）

Record/Project 语义；Universal Input 的 Search+Create 合一；Enter 默认创建；Input→Scope→List 结构与无 Sidebar 单表面；`↑↓/←→/Enter/Space/⌘Number` 键盘语义；Project 唯一手动顺序；Local-first；No Silent Data Loss；SQLite+CloudKit 方向；PRD §2.2 非目标列表。

## 工程铁律（详见 SPEC.md）

- 零第三方依赖；AppKit 纯代码；Swift 5 语言模式；UI 主线程 + DB 单串行队列单连接 + 事务写入。
- 反过度设计：同一模式第三次出现才抽象；不为"未来可能"预留接口；防御只在数据落盘/外部输入边界，内部用断言。
- **平台原生优先**：先找 AppKit 现成控件与样式，自绘是最后手段且要在 ARCHITECTURE §8 登记原因。
- 测试只覆盖三类：存储层、纯逻辑、冲突合并。不写 UI 自动化——UI 用 `--ui-smoke` + 人工冒烟。
- **同步义务**：改 UI 行为必须扩展 UISmokeRunner 断言（曾因缺窗口几何断言漏过"窗口坍缩到 28pt"）；改键盘必须更新 README 键盘表；改 schema 必须更新 docs/SCHEMA.md；新增/删除源文件必须 `xcodegen generate` 并提交 pbxproj。
- 代码组织：控制器按关注点拆 extension 文件（`MainViewController+Records/+Projects/+Smoke`）；模态弹窗进 `Dialogs`；UserDefaults 键进 `Preferences`；不新建"Manager/Service/Helper"类。
- 工程配置只改 `project.yml`，然后 `xcodegen generate`，两者一起提交。**严禁手改 project.pbxproj**（包括在 Xcode 界面里点设置——点完必须回填 project.yml 再重新生成）。

## 命令速查

```bash
swift build && swift test          # 快速通道；测试必须秒级全绿
.build/debug/Inbox --ui-smoke      # 进程内 UI 冒烟（临时库，退出码 0 = PASS）
xcodegen generate                  # 改 project.yml 或增删源文件后重新生成工程
xcodebuild -project Inbox.xcodeproj -scheme Inbox -configuration Debug \
  -derivedDataPath /tmp/inbox-dd -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration build   # 带签名/entitlements 的 .app
```

CloudKit 双库端到端验证（单机模拟双设备，需系统已登录 iCloud）：

```bash
BIN=/tmp/inbox-dd/Build/Products/Debug/Inbox.app/Contents/MacOS/Inbox
"$BIN" --sync-probe create --content "probe-123" --db-path /tmp/a.sqlite --defaults-suite p.a
"$BIN" --sync-probe expect --content "probe-123" --db-path /tmp/b.sqlite --defaults-suite p.b --timeout 90
```

## Git 约定

- main 始终可构建可运行；工作走 `feat/<slug>` / `fix/<slug>` / `refactor/<slug>` 分支，完成后 `--no-ff` 合并，合并后删分支。
- 提交小步、单一关注点，英文小写祈使句，可加范围前缀（如 `fix:`、`ui:`、`refactor:`、`docs:`）；末尾加 `Co-Authored-By: <模型名> <noreply@...>`。
- 合并四道门：`swift build`、`swift test`、`--ui-smoke` PASS、冒烟/审阅。UI 或同步相关改动加跑 xcodebuild 与（必要时）sync-probe。合并后在 docs/HISTORY.md 时间线补一行。
- 参数微调级别的小修（间距、颜色、常量）可以不跑 `--ui-smoke`，但合并前必须跑。

## 已知坑

- CloudKit 容器 `iCloud.com.xiaolin.Inbox` 当前为 **Development** 环境；分发前须切 Production 并部署 schema。
- 冒烟合成的键盘事件必须同时带 keyCode 与字符（`RecordTableView` 按字符判定）；只给 keyCode 的事件会被表格忽略。
- **两张列表都不用 `usesAutomaticRowHeights`**（R19 决定）：自动行高下 `reloadData()` 会把所有行重置为估算高度再在显示时逐行实测，滚动偏移在中间被夹住（编辑提交后列表跳一行）；`noteHeightOfRows` / `reloadData(forRowIndexes:)` 只长不缩；改宽时在 `setFrameSize` 里重载还会丢选区。现在行高由 delegate `heightOfRow` 给出——`RecordCellView.displayHeight(for:style:tableWidth:)` 用与绘制相同的 `WrappingTextFieldCell.cellSize` 测量并按内容缓存；编辑中的行由 `editingRowHeight` 提供。改宽只需 `noteHeightOfRows`（精确、可缩），但必须推迟到下一轮 run loop——在 `setFrameSize`（表自己的 tile 里）同步调用会触发 AppKit 的 "reentrant operation in its NSTableView delegate" 警告。`heightOfRow` 里不得向表要 cell view（同样是重入）。
- `RecordTableView.scrollRowToVisible` 被重写为"行必须完整落在上下两条栏之间"（按 `contentInsets` 算），所有"露出这一行"的路径（↑↓、Resolve/Trash 后继承焦点、编辑提交、搜索结果）都走它；AppKit 原版只保证在 clip 内，会把行留在栏下面的溶解区里。
- 底栏用自绘 `ScopeChipButton` 是实测后的决定（比平台 accessory-bar 按钮便宜，见 HISTORY R7），不要"顺手"换成 `NSButton`。
- 窗口尺寸：顶层 surface 用 autoresizing 而非四边 Auto Layout 钉死——否则窗口会吸附 fitting size 坍缩（见 HISTORY「窗口坍缩事故」）。
- `NSScrollView.contentInsets` 只有在 `contentView.automaticallyAdjustsContentInsets` 保持 `true` 时才会传到 clip view（R10 查明；之前以为它"不扩展滚动范围"）。Scope Bar 的尾部留白仍用 stack 的 edgeInsets。
- 列表滚动视图必须是 `OverlayScrollView`：AppKit 会在系统首选样式变化（接鼠标）时把 `scrollerStyle` 改回 legacy，一次性设 `.overlay` 挡不住。
- 列表上下用 `EdgeDissolve`（`CAGradientLayer` 作 `scrollView.layer.mask`）；这个 layer 的 unit y=0 在顶部，改遮罩先看 `main-scrolled-*` 快照核对方向。
- xctrace `--launch` 按 bundle id 经 LaunchServices 取包，会拿到 DerivedData 里的旧 Debug 包；剖析 Release 要复制包改 CFBundleIdentifier 并 `codesign --force --deep --sign -`（HISTORY 决策 10）。
- 跨 SDK 版本：macOS 27 SDK 的新成员（如 `NSGlassEffectView.effectIsInteractive`）在 26 上编译失败，`#available` 救不了编译期——用 KVC。
- SPM 裸二进制（`swift run`）没有 bundle/entitlements：同步与 Launch at Login 自动禁用，属预期。
