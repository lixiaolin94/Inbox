# Inbox 开发协作 Spec

> 版本：v0.1（2026-08-20）
> 本文件是所有参与开发的 Agent 的共同前提。优先级：PRD 产品语义 > 本 Spec > 执行 Agent 现场决策。
> PRD 未规定的实现细节按本 Spec 执行；本 Spec 未覆盖的由执行 Agent 决策，并在交付说明中记录。

## 1. 角色分工

| 角色 | 模型 | 通道 | 职责 |
|---|---|---|---|
| 协调者 | Fable | — | 拆分 Slice、派发任务、审阅代码、构建冒烟、合并决策、对外汇报。不直接编写产品代码。 |
| 主力编码 | Grok 4.6 xhigh | 本机 Grok CLI headless（`~/.grok/bin/grok --prompt-file … --model grok-4.6 --reasoning-effort xhigh`，工作目录锁定本仓库） | 自 S3b 起的所有常规功能开发与单元测试。 |
| 备用编码 / 杂务 | Sonnet / Haiku | 内建 Agent | Grok 通道不可用时顶替；机械性批量修改、脚本。（S1、S2、S3a 由 Sonnet 完成。） |
| 攻坚 | Opus | 内建 Agent | 仅用于主力编码两轮迭代仍未解决的疑难问题、同步/冲突等高风险设计。 |

同一时间主线上只有一个活跃编码 Slice；相互独立的杂务可用 git worktree 并行。

## 2. 技术基线（PRD 已定项之外的补充决策）

- **工程形态**：双通道。SPM（`swift build` / `swift test` / `swift run`）用于快速滚动验证与 CI；XcodeGen 生成的 `Inbox.xcodeproj` 用于 Xcode 打开与 .app 构建。`project.yml` 是唯一权威工程描述；生成的 `.xcodeproj` 入库（保证 clone 后 Xcode 直接打开），改工程配置必须改 `project.yml` 后重新 `xcodegen generate`，不得手改 pbxproj。（v0.1 修订：原"不入库"决定因用户要求 clone 即开而调整。）
- **零第三方依赖**：SQLite 使用系统 libsqlite3 + 自写薄封装。禁止引入 ORM、响应式框架、DI 框架、任何 SPM 第三方包。
- **最低系统版本**：macOS 14（CKSyncEngine 需要）。
- **UI**：AppKit 纯代码构建，无 storyboard / xib。
- **语言模式**：Swift 5 语言模式，暂不开启 Swift 6 严格并发检查（避免为并发标注消耗迭代速度）。
- **并发模型**：UI 全部在主线程；数据库访问走单一串行队列；未来同步逻辑在后台。不引入 actor / 复杂泛型抽象。

## 3. 代码质量守则（反过度设计）

- **按需抽象**：同一模式出现第三次才允许抽象。禁止为“未来可能需要”预留协议、泛型、配置项、扩展点。
- **防御边界**：只在数据落盘与外部输入处（DB 读写、文件、未来同步）做校验和错误处理；内部逻辑用 `precondition`/`assert` 表达不变量，不写永远走不到的 fallback 分支。
- **错误处理**：可恢复错误显式向上传播；不可恢复错误 fail fast。任何路径不得静默丢弃用户输入（PRD：No Silent Data Loss）。
- **命名**：与 PRD 术语一致（Record / Project / Scope / Priority / Resolve / Trash）。
- **注释**：只写代码本身表达不了的约束与原因，不写流水账。
- 文件与函数保持小而直白；一个类型做一件事，但不为拆而拆。

## 4. 测试策略（反过度测试）

- 单元测试**只**覆盖三类：存储层（schema、CRUD、FTS、迁移）、纯逻辑（排序、Focus 继承规则、Priority 边界）、未来的冲突合并算法。
- **不做 UI 自动化测试**。UI 用每个 Slice 附带的人工冒烟清单验证（协调者执行 + 用户手感确认）。
- 性能按 PRD §17 指标在相关 Slice 完成时抽查并记录一次，不建常驻 benchmark 设施。
- `swift test` 必须秒级完成，是合并门槛之一。

## 5. Git 工作流

- **main**：始终可构建、可运行，只接受协调者审阅后的合并。
- **分支**：功能 `feat/s<N>-<slug>`，修复 `fix/<slug>`。
- **提交粒度**：每个可编译、可独立说明的步骤一次提交；禁止一次提交混合多个功能点。
- **提交信息**：`s1: add sqlite store and schema v1` 风格（slice 前缀 + 英文小写祈使句）。
- **合并条件**：`swift build` 成功、`swift test` 通过、Slice 冒烟清单通过、协调者审阅完成。
- **回退**：Slice 出问题优先 revert 该分支的合并提交，而不是原地打补丁。

## 6. 流水线

```text
协调者拆 Slice 并给出验收
→ 编码 Agent 在分支上小步提交实现并自测
→ 提交交付说明（实现摘要 / 关键决策 / 遗留问题）
→ 协调者审阅 + 构建 + 冒烟
→ 合并 main（打 tag 可选）
→ 派发下一个 Slice
```

每个 Slice 的验收标准由协调者在派发时依据 PRD §19 / §22.3 给出。

## 7. Slice 队列（Phase 0 → MVP）

| # | 名称 | 范围 |
|---|---|---|
| S1 | 捕获核心 | 窗口 + Universal Input + Record List + SQLite/FTS + Enter 创建 + 输入即搜索 + ↑↓ 焦点进出列表 |
| S2 | 键盘模型 | Row Focus 状态机、←→ Priority、Space Resolve/Reopen、Enter Inline Edit、Esc、Focus 继承规则 |
| S3 | Project 与 Scope | Scope Bar、All 分组/折叠、⌘Number、Project CRUD 与手动排序、Record 移动 Project |
| S4 | 组织闭环 | 时间/优先级排序、Show Resolved、软删除 + Undo、Trash 界面（Restore / 永久删除） |
| S5 | 应用形态 | XcodeGen 出 .app、Dock + 菜单栏驻留、激活与首键不丢、Launch at Login、Quick Add |
| S6 | CloudKit 同步 | CKSyncEngine 最小 Project + Record 同步、冲突无损（需开发者账号，届时与用户确认） |
| S7 | 打磨与开放数据 | 性能测量记录、Schema 文档、导出边界、Accessibility 基线 |

顺序可由协调者根据风险调整，但每个 Slice 必须独立可验证、可回退。
