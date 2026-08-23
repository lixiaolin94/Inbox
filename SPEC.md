# Inbox 开发协作 Spec

> 版本：v0.2（2026-08-22；v0.1 为 2026-08-20）
> 本文件是所有参与开发的人与 Agent 的共同前提。优先级：PRD 产品语义 > 本 Spec > 执行者现场决策。
> PRD 未规定的实现细节按本 Spec 执行；本 Spec 未覆盖的由执行者决策，并在交付说明中记录。
> 结构与文件职责见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，历史与遗留见 [docs/HISTORY.md](docs/HISTORY.md)。

## 1. 角色

两种角色，谁来担任随设备与会话而变，**不变的是守则与合并门槛（§3–§6、§8–§9）**：

| 角色 | 职责 |
|---|---|
| 协调者（用户本人或模型） | 定范围与验收、审阅、独立跑四道门、合并决策、维护 HISTORY |
| 执行者（当时可用的任何模型） | 在分支上小步提交实现与自测，提交交付说明（实现摘要 / 关键决策 / 遗留） |

同一时间主线上只有一个活跃分支在改同一块代码；相互独立的杂务可用 git worktree 并行。新会话开工前按仓库根 CLAUDE.md 的顺序读文档。

## 2. 技术基线（PRD 已定项之外的补充决策）

- **工程形态**：双通道。SPM（`swift build` / `swift test` / `swift run`）用于快速滚动验证与 CI；XcodeGen 生成的 `Inbox.xcodeproj` 用于 Xcode 打开与 .app 构建。`project.yml` 是唯一权威工程描述；生成的 `.xcodeproj` 入库（保证 clone 后 Xcode 直接打开）。改工程配置或增删源文件必须 `xcodegen generate` 并一起提交，不得手改 pbxproj。
- **零第三方依赖**：SQLite 使用系统 libsqlite3 + 自写薄封装。禁止引入 ORM、响应式框架、DI 框架、任何 SPM 第三方包。
- **最低系统版本**：macOS 14（CKSyncEngine 需要）。macOS 26+ 的 Liquid Glass 通过 `#available` 分支使用并提供 fallback；跨 SDK 缺失的成员用 KVC，不提升最低版本。
- **UI**：AppKit 纯代码构建，无 storyboard / xib，无 SwiftUI（框架选型复核见 ARCHITECTURE §7）。
- **语言模式**：Swift 5 语言模式，暂不开启 Swift 6 严格并发检查。
- **并发模型**：UI 全部在主线程；数据库访问走单一串行队列单连接；同步逻辑在 DB 队列上落库。不引入 actor / 复杂泛型抽象。

## 3. 代码质量守则（反过度设计）

- **按需抽象**：同一模式出现第三次才允许抽象。禁止为"未来可能需要"预留协议、泛型、配置项、扩展点。
- **防御边界**：只在数据落盘与外部输入处（DB 读写、文件、同步）做校验和错误处理；内部逻辑用 `precondition`/`assert` 表达不变量，不写永远走不到的 fallback 分支。
- **错误处理**：可恢复错误显式向上传播；不可恢复错误 fail fast。任何路径不得静默丢弃用户输入（PRD：No Silent Data Loss）。
- **命名**：与 PRD 术语一致（Record / Project / Scope / Priority / Resolve / Trash）。
- **注释**：只写代码本身表达不了的约束与原因，不写流水账。
- **代码组织**：
  - 一个类型做一件事，但不为拆而拆。控制器超过约 600 行时按关注点拆成同名 `+Concern.swift` extension 文件（现状：`MainViewController` / `+Records` / `+Projects` / `+Smoke`），共享成员设为模块内可见并在类型头注释说明；不引入 Coordinator/Presenter/Manager 之类的新层。
  - 模态弹窗进 `Dialogs`；UserDefaults 键进 `Preferences`；多处复用的扇出/计数类 plumbing 进存储层的静态方法（如 `RecordStore.batch`）。
  - `--ui-smoke` 的探针只放在 `+Smoke.swift`，只读，不改状态。
  - 源文件按层放目录（`App / Surfaces / Views / Model / Storage / Sync / Diagnostics`，见 ARCHITECTURE §2）；不按"功能"再建第二套目录。
  - 死代码随手删，不留"以后可能用"。

## 4. 测试策略（反过度测试）

- 单元测试**只**覆盖三类：存储层（schema、CRUD、FTS、迁移）、纯逻辑（排序、Focus 继承规则、Priority 边界、行映射）、冲突合并算法。
- **不做 UI 自动化测试**。UI 用 `--ui-smoke`（进程内合成键盘事件 + 几何断言）加人工冒烟验证。
- 性能按 PRD §17 指标在相关改动完成时抽查并记录一次，不建常驻 benchmark 设施。
- `swift test` 必须秒级完成，是合并门槛之一。

## 5. Git 工作流

- **main**：始终可构建、可运行，只接受审阅后的 `--no-ff` 合并；合并后删除分支（本地与远端）。
- **分支**：`feat/<slug>`、`fix/<slug>`、`refactor/<slug>`。
- **提交粒度**：每个可编译、可独立说明的步骤一次提交；禁止一次提交混合多个关注点。
- **提交信息**：英文小写祈使句，可加范围前缀（`fix:`、`ui:`、`refactor:`、`docs:`、`test:`、`chore:`），正文写"为什么"；末尾 `Co-Authored-By`。
- **回退**：出问题优先 revert 合并提交，而不是原地打补丁。

## 6. 合并四道门

```text
swift build  →  swift test  →  .build/debug/Inbox --ui-smoke PASS  →  审阅 + 人工冒烟
```

涉及工程配置/签名/同步的改动加跑 xcodebuild（带 provisioning flags）与必要时的 `--sync-probe` 双库验证。合并后在 docs/HISTORY.md 时间线追加一行，完成的遗留事项打勾、新发现的补录。

## 7. 里程碑

MVP 的 Slice 队列 S1–S6 已于 2026-08-21 全部合并（v0.2.0），之后按 §8 小版本工作流推进；时间线与关键决策见 docs/HISTORY.md。下一阶段主题：基础瘦身（已完成）、UI 打磨（平台组件优先，候选清单在 ARCHITECTURE §8）、S7 打磨项（激活时延、Accessibility、导出）。

## 8. 小版本工作流

- **一样走分支**：再小的改动也不直接在 main 上提交（docs 与工程配置微调除外）。
- **合并门槛不降**（§6）。参数微调级别的小修（间距、颜色、常量）在迭代中可以不跑 `--ui-smoke` 以加快手感反馈，但合并前必须跑。
- **同步义务**（改了就必须一起改，不欠账）：
  - UI 行为/几何变化 → 扩展 UISmokeRunner 断言；
  - 键盘语义变化 → 更新 README 键盘速查表（且不得触碰 PRD §22.2 红线）；
  - schema 变化 → user_version 步进迁移 + docs/SCHEMA.md；
  - 工程配置或源文件增删 → 改 project.yml / `xcodegen generate`，提交 pbxproj；新增纯逻辑文件加入 InboxTests 的 includes；
  - 结构性变化 → 更新 docs/ARCHITECTURE.md 的文件职责表或不变量。
- **范围纪律**：一个分支解决一件事；顺手发现的其他问题记入 docs/HISTORY.md 清单，不在当前分支夹带。
- **产品语义存疑时停下问用户**，尤其 HISTORY「产品待定」小节里的条目。

## 9. UI 组件原则：平台原生优先

目标是"平台最佳性能 + 最少自定义"，让系统升级自动带来外观与行为改进。

1. **先找平台组件**：`NSButton` 的 bezelStyle（`.accessoryBarAction`、`.badge`、玻璃样式）、`NSTableView` group rows / `NSOutlineView`、`NSSearchField`、`NSSegmentedControl`、`NSVisualEffectView` / `NSGlassEffectView`、标准 Settings 窗口、`NSMenu`。
2. **自绘是最后手段，但要量**：只有平台控件无法表达 PRD 语义（例如 chip 选中不改宽度、`refusesFirstResponder` 保住 Input 焦点）或实测明显更贵时才自绘，并在 ARCHITECTURE §8 登记"为什么"。替换自绘前先做控件微基准（HISTORY 决策 15）——实测系统 bezel 的首绘/重绘可能比轻量自绘贵一个量级。
3. **workaround 要标注退出条件**：例如 `TitlebarBackdrop`、`ClearTableRowView` 的居中修正，系统修复后删除。
4. **替换顺序**：先低风险（Utility/Trash 栏按钮）、后高风险（Scope chip、分组折叠）；每一步跑 `--ui-smoke` 并人工确认键盘语义不变。
5. **度量**：替换前后各记一次启动/激活时延与二进制体积，不凭感觉。
