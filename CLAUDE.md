# Inbox — Agent 上手指南

Inbox 是 Swift + AppKit 的 macOS 个人 Record 管理工具（Keyboard-first、Local-first、CloudKit 同步）。本文件是任何 Agent 在任何设备上开工前的入口。

## 读文档的顺序

1. 本文件（约定与命令速查）；
2. [SPEC.md](SPEC.md) —— 工程守则：质量红线、测试策略、Git 工作流、小版本工作流；
3. [Inbox_macOS_MVP_PRD_v0.1.md](Inbox_macOS_MVP_PRD_v0.1.md) —— 产品语义的唯一权威（改交互前必读相关章节）；
4. [docs/HISTORY.md](docs/HISTORY.md) —— 已做过什么、为什么这么做、已知遗留事项（**接小任务先查这里的清单**）；
5. [docs/SCHEMA.md](docs/SCHEMA.md) —— 数据库结构（改存储前必读）。

## 产品红线（PRD §22.2，不得未经用户评审改变）

Record/Project 语义；Universal Input 的 Search+Create 合一；Enter 默认创建；Input→Scope→List 结构与无 Sidebar 单表面；`↑↓/←→/Enter/Space/⌘Number` 键盘语义；Project 唯一手动顺序；Local-first；No Silent Data Loss；SQLite+CloudKit 方向；PRD §2.2 非目标列表。

## 工程铁律（详见 SPEC.md）

- 零第三方依赖；AppKit 纯代码；Swift 5 语言模式；UI 主线程 + DB 单串行队列单连接 + 事务写入。
- 反过度设计：同一模式第三次出现才抽象；不为"未来可能"预留接口；防御只在数据落盘/外部输入边界，内部用断言。
- 测试只覆盖三类：存储层、纯逻辑、冲突合并。不写 UI 自动化——UI 用 `--ui-smoke` + 人工冒烟。
- **改 UI 行为必须同步扩展 UISmokeRunner 断言**（曾因缺窗口几何断言漏过"窗口坍缩到 28pt"的事故），改键盘必须同步更新 README 键盘表，改 schema 必须同步 docs/SCHEMA.md。
- 工程配置只改 `project.yml`，然后 `xcodegen generate`，两者一起提交。**严禁手改 project.pbxproj**（包括在 Xcode 界面里点设置——点完必须回填 project.yml 再重新生成）。

## 命令速查

```bash
swift build && swift test          # 快速通道；测试必须秒级全绿
.build/debug/Inbox --ui-smoke      # 进程内 UI 冒烟（临时库，退出码 0 = PASS）
xcodegen generate                  # 改 project.yml 后重新生成工程
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

- main 始终可构建可运行；工作走 `feat/<slug>` / `fix/<slug>` 分支，完成后 `--no-ff` 合并。
- 提交小步、单一关注点，英文小写祈使句，可加范围前缀（如 `s7:`、`fix:`、`docs:`）；末尾加 `Co-Authored-By: <模型名> <noreply@...>`。
- 合并四道门：`swift build`、`swift test`、`--ui-smoke` PASS、冒烟/审阅。UI 或同步相关改动加跑 xcodebuild 与（必要时）sync-probe。

## 已知坑

- CloudKit 容器 `iCloud.com.xiaolin.Inbox` 当前为 **Development** 环境；分发前须切 Production 并部署 schema。
- 键盘用硬编码 keyCode（RecordTableView.swift），非美式键盘布局下 `M` 键可能失效（HISTORY 清单有记录）。
- 窗口尺寸：顶层 surface 用 autoresizing 而非四边 Auto Layout 钉死——否则窗口会吸附 fitting size 坍缩（见 HISTORY「窗口坍缩事故」）。
- SPM 裸二进制（`swift run`）没有 bundle/entitlements：同步与 Launch at Login 自动禁用，属预期。
