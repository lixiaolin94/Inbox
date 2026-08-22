# 发布准备计划与清单（v0.3.0）

> 2026-08-22 起由协调者自动化推进。状态随每轮合并更新；"需要用户"一栏是只有账号/设备持有人能做的事。产品语义以 PRD 为准，新引入的交互在 HISTORY「产品待定」登记等用户评审。

## 0. 前提：工程结构已稳定

R5–R8 之后：源码按层分目录、控制器按关注点拆分、守则与验证矩阵在 SPEC/ARCHITECTURE、冒烟覆盖窗口几何/底栏/Trash/键盘链路/warm 激活、性能基线与测量方法在 HISTORY。本计划只做功能与发布项，不再动结构。

## 1. 优先级（用户 2026-08-22 拍板）

| 优先级 | 项 | 依据 |
|---|---|---|
| 高 | 冲突处理 UI | PRD §15.3、§18.2 |
| 高 | 数据导出入口 | PRD §16.1 |
| 高 | FTS / 搜索在大数据量下复查 | PRD §17.3 |
| 高 | CloudKit 切 Production 与发布流程 | CLAUDE.md 已知坑 |
| 高 | UI 像素级稳定性排查 | 用户要求 |
| 低 | Accessibility | 只做平台默认兜底的简单配置，不投入 |

## 2. 轮次

### 第一轮（并行，文件边界互不重叠）

| 执行者 | 范围 | 产出 |
|---|---|---|
| FTS 复查 | `Storage/RecordStore.swift`、`Tests/` | 10k / 50k / 100k 行（中英混合）下 LIKE 与 FTS5 MATCH 的 p50/p95；若 LIKE 在 100k 仍 ≤ 50 ms 则保留，否则 ≥3 字符走 MATCH、短词回退 LIKE；数字进 HISTORY |
| 导出 | `Model/Export.swift`（新，纯逻辑）、`App/AppDelegate.swift`（File 菜单）、`Surfaces/Dialogs.swift`（保存面板）、`Tests/` | File ▸ Export as JSON…（全部 Record 含 Trash + Project + 导出元数据）、File ▸ Export Database Snapshot…（`VACUUM INTO`，WAL 下一致快照）、File ▸ Show Data in Finder |
| 像素审查工具 | `Diagnostics/UISmokeRunner.swift`、`App/LaunchConfiguration.swift`、`Surfaces/MainViewController+Smoke.swift` | `--ui-smoke --snapshot-dir <dir>`：主表面（浅/深色 × 480/720/1100 宽 × 普通/Show Resolved/长文本换行）与 Trash 表面渲染为 PNG；关键 frame 像素对齐断言 |
| 协调者 | `project.yml`、entitlements、本文档 | Debug=Development / Release=Production 的 per-config 容器环境；发布清单 |

### 第二轮（串行）

冲突处理 UI（PRD §15.3）。设计（协调者决定，登记产品待定）：

1. schema v4：`record.conflict_of TEXT`——Keep Both 生成的副本记录原始 id，**随 CloudKit 同步**（`conflictOf` 字段），两端都能看到待处理的冲突对；解决后清空。
2. 列表：`conflict_of` 非空的行在时间列位置显示弱化的"Conflict"标签（不改行高、不改键盘语义）。
3. Utility 栏：存在冲突时在离线标签位置显示弱化的"N conflicts"chip，点击把列表过滤到冲突对（再点取消）。
4. 解决：冲突行的右键菜单 / `M` 同级新增 "Resolve Conflict ▸ Keep This / Keep Other / Keep Both"。Keep This = 对方移入 Trash（可恢复，无损）；Keep Other = 本行移入 Trash；Keep Both = 清空标记。不做新的 surface。
5. 同步长期失败的可诊断状态：Settings 里显示上次成功同步时间与最近错误（只读文本），不做轮询。

### 第三轮（收口）

- Accessibility 最小配置：symbol chip 的 `accessibilityLabel`、组头的 role、Trash 行的描述；不做 VoiceOver 深度走查。
- 像素审查：协调者逐张看第一轮产出的 PNG，异常记入清单并修。
- 版本 0.3.0、README/HISTORY/SCHEMA 刷新、`--sync-probe` 双库验证、四道门。

## 3. 发布清单

| 步骤 | 谁 | 状态 |
|---|---|---|
| Release 配置使用 Production 容器环境（entitlements 按配置取值：`$(ICLOUD_CONTAINER_ENVIRONMENT)` / `$(APS_ENVIRONMENT)`）。已验证：Release 构建产物 `icloud-container-environment = Production`；`aps-environment` 在本地 Apple Development 签名下仍为 development，由 provisioning profile 决定，归档用分发 profile 时为 production | 协调者 | 完成（`release/cloudkit-env`） |
| 在 CloudKit Console 把 Development schema **Deploy to Production**（Record/Project 两个 Record Type 及索引；**含 R9 新增的 `Record.conflictOf` 字段**——本轮 sync-probe 已让它出现在 Development schema 里） | **用户**（需 Apple ID 登录 Console） | 待办 |
| 决定分发方式：Developer ID 直发（需公证）或 App Store；对应 `ENABLE_HARDENED_RUNTIME` 与签名身份 | **用户** | 待办 |
| Archive（Xcode Product ▸ Archive 或 `xcodebuild archive`）并导出 | 用户/协调者 | 待办 |
| 首次在 /Applications 形态下人工确认 Launch at Login 注册 | 用户 | 待办 |
| 用 Release 包做一次 `--sync-probe` 双库验证（需 Production schema 已部署） | 协调者 | 待办（Debug/Development 已通过，见状态日志） |
| 清理开发容器里的探针记录 | 用户（App 内 ⌫） | 待办 |

## 4. 状态日志

- 2026-08-22：计划建立；第一轮开始。
- 2026-08-22：第一轮四项全部合入集成分支（FTS 结论：保留 LIKE；导出三入口；Settings 同步状态；快照工具）；像素审查修 5 处、1 处留人工确认（深色输入框玻璃）；第二轮冲突中心存储层 + UI 合入；Accessibility 最小配置进行中；版本号 0.3.0；Debug 包对 Development 容器的 `--sync-probe` 双库验证通过（UPLOADED → FOUND，含 schema v4 的 `conflictOf` 字段）。
