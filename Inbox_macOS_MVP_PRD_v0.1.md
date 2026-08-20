# Inbox macOS MVP 产品需求文档

> 版本：v0.1  
> 状态：第一版产品与技术基线  
> 日期：2026-08-20  
> 主平台：macOS  
> 后续平台：iOS  
> 文档用途：交付本地执行 Agent，用于原型验证、技术设计、开发拆分与迭代验收

---

## 0. 文档目的与决策优先级

本文档定义 Inbox 的产品边界、核心交互、技术选型、数据与同步原则、MVP 范围和长期演进方向。

它不是详细技术设计，也不规定代码分层、具体第三方库、数据库封装方式、线程模型或类结构。这些实现细节由本地执行 Agent 根据快速原型、性能验证和维护成本自行决策。

当实现选择发生冲突时，按以下顺序判断：

1. **产品基石与核心理念**；
2. **用户可感知的交互语义**；
3. **数据安全、开放性与同步原则**；
4. **性能和可靠性目标**；
5. **技术选型边界**；
6. **具体实现便利性**。

不得为了减少短期代码量而改变前四项。

## 0.1 已确定方案总览

| 领域 | 已确定方案 | 核心目的 |
|---|---|---|
| 产品形态 | 独立 macOS App；Raycast 仅作为首选启动入口 | 专事专做，避免把工作流寄宿在通用启动器中 |
| 产品对象 | `Record`、`Project`、未来 `Attachment` | 用最少概念覆盖 Todo、Issue、Bug、发现和想法 |
| macOS 技术 | Swift + AppKit，必要时使用 Core Animation | 原生输入、焦点、菜单栏、低延迟和长期稳定性 |
| UI 结构 | Universal Input → Scope Bar → Record List → Utility | 单表面、输入优先、无 Sidebar 页面层级 |
| 本地数据 | 每台设备一个 SQLite，本地先提交 | 快速、离线、事务、全文搜索、开放可读 |
| 搜索 | Universal Input 内实时全文搜索 | 搜索不是模式；输入时自然 Recall |
| 同步 | CloudKit 记录级同步，优先验证 CKSyncEngine | 多设备各自本地工作，后台合并，不同步活动数据库文件 |
| 附件 | 独立 Attachment Entity，归属于 Record | 为图片、视频和文件预留稳定扩展关系 |
| iOS | 明确长期路线，原生 Touch-first 完整客户端 | 共享数据哲学，不机械复制 Mac UI |
| 外部集成 | 未来可选 Raycast Companion、CLI、Agent Interface | 集成不取代独立产品，读开放、写走稳定接口 |

---

# 1. 产品定义

## 1.1 产品定位

**Inbox 是一个面向个人开发者、Keyboard-first、Local-first 的快速工作 Record 管理工具。**

它用于记录和处理开发过程中随时出现的：

- Todo；
- Issue；
- Bug；
- Observation；
- Idea；
- Reminder；
- 待确认事项；
- 暂时无法准确归类、但需要保留和处理的任何工作内容。

系统不要求用户在创建前判断它属于哪一种类型。所有内容统一称为 **Record**。

## 1.2 核心闭环

```text
想到一件事
    ↓
直接输入
    ↓
输入过程中看到相关已有 Record
    ↓
不处理搜索结果则 Enter 直接创建
    ↓
通过 Project、Priority、排序进行轻量组织
    ↓
处理完成后 Resolve
```

产品的核心体验不是“填写任务表单”，而是：

> **想到就输入，输入即查找，回车即记录。**

## 1.3 目标用户与规模假设

首要目标用户是个人开发者，尤其是同时处理多个个人或工作项目、需要快速记录发现与待办的人。

产品主动围绕以下真实规模设计：

- Project：通常为个位数，极端情况下十几个；
- 活跃 Open Record：通常为几十到几百条；
- 长期历史 Record：可能逐渐增长到数千或更多；
- 用户：单人；
- 协作：MVP 不存在。

Inbox **不以数百 Project、成千上万活跃任务或多人团队管理为目标**。不得为了这类假设提前引入复杂导航、权限、工作区和层级模型。

## 1.4 为什么是独立应用，而不是 Raycast Extension

Raycast 对目标用户的主要价值是一个统一的**启动与导航入口**：

```text
唤出 Raycast
→ 输入 Inbox
→ Enter
→ Raycast 退场
→ Inbox 接管工作
```

Inbox 不应寄宿在 Raycast 内完成完整工作流，原因包括：

- 用户不希望记忆 Extension 名称、前缀、子命令或另一套快捷键；
- 用户希望通用启动器负责“去哪里”，专用工具负责“把一件事做好”；
- Raycast 内部工作流会引入返回、退出、界面残留和宿主状态等额外心智；
- Inbox 的核心价值包含一套独立、稳定、可形成肌肉记忆的 Record 操作语言；
- 产品长期计划包含完整 iOS 客户端、开放数据和自有同步模型。

因此，Raycast 在 MVP 中的角色是：

> **Preferred Launch Surface，而不是 Workflow Host。**

Inbox 不依赖 Raycast 才能完整运行。未来可以增加可选 Companion Extension，但不得把核心体验迁入 Raycast。

## 1.5 产品基石

### 专事专做

Inbox 不试图成为第二个 Raycast、Linear、Notion、Jira、AI 工作台或项目管理平台。它只专注于快速记录、查找、组织和解决 Record。

### 简单是主动约束，不是功能未完成

产品围绕个人真实工作负载设计。少数概念、稳定行为和直接反馈优先于功能广度。

### 手感是核心资产

AI 时代实现一个功能越来越容易，但做出稳定、直接、精细且可形成肌肉记忆的产品仍然困难。Inbox 的竞争力不是功能数量，而是焦点、按键、反馈、排序、插入和恢复等微小决策共同形成的整体手感。

### 认知速度优先

“快”不只指毫秒和帧率，也包括少一次命令判断、少一个模式、少一次页面跳转。减少用户思考“接下来进入哪个功能”往往比减少几十毫秒更重要。

### Input First

用户进入主窗口后首先面对输入，而不是导航、项目选择或创建表单。

### Capture First

Project、Priority 等组织信息不得成为创建 Record 的前置条件。

### Search While Typing

搜索不是独立模式。用户输入新内容时，系统同步展示相关已有 Record。

### Create by Default

只要用户没有主动把焦点移动到现有 Record，Enter 的默认语义永远是创建当前输入内容。

### Keyboard First

高频操作必须形成稳定、低修饰键、空间一致的键盘模型。支持鼠标，但鼠标不是主要路径。

### Single Surface

主窗口不采用 Sidebar → Page → Detail → Form 的传统导航层级。主要工作始终发生在同一个表面：

```text
Input
↓
Scope
↓
List
```

### Local First

所有高频操作先完成本地持久化和 UI 响应，再异步同步。网络不得进入 Capture、Search、Resolve 等关键路径。

### No Silent Data Loss

任何创建、编辑、同步、冲突或异常都不得静默丢失用户输入。

### Open Data

数据属于用户。格式和结构应尽量开放、稳定、可导出、可由脚本和 Agent 读取。

### Platform-native Interaction

macOS 和未来 iOS 共享产品哲学和数据语义，但使用各自最自然的输入方式，不机械复用 UI。

---

# 2. 产品目标与非目标

## 2.1 MVP 产品目标

1. 用户通过 Raycast、Dock 或菜单栏进入 Inbox 后，可以立即输入；
2. 创建 Record 的最短路径是：输入单行 Content → Enter；
3. 输入过程中即时检索当前 Scope 中的相关 Record；
4. 用户可以在不离开主表面的情况下完成浏览、编辑、调整 Priority、Resolve 和 Project 归属；
5. 用户可以用少量稳定按键完成绝大多数高频操作；
6. Project 只作为轻量 Scope，不引入页面和层级管理；
7. Record、Project、Resolve、Trash、Search 和排序形成完整 CRUD 闭环；
8. 应用在无网络、iCloud 不可用或同步延迟时仍可完整使用；
9. 本地数据可开放读取，并为未来 Agent 集成保留稳定边界；
10. 数据模型从一开始支持未来附件和 iOS 多设备同步，而不要求 MVP 提供附件 UI 或 iOS 客户端。

## 2.2 明确非目标

MVP 不做：

- Todo / Issue / Bug 等 Record Type；
- Title + Description 双字段；
- 多行 Content；
- Due Date；
- Deadline；
- Reminder；
- Calendar；
- Sprint / Cycle；
- Milestone；
- Estimate；
- Label / Tag；
- Comment；
- Team；
- User / Assignee；
- Collaboration；
- Permission；
- Nested Project；
- Folder Tree；
- Multiple Workspace；
- Project Status / Progress；
- Rich Text；
- 附件 UI；
- AI 功能；
- Web 版本；
- Windows / Linux 版本；
- 自有全局 Capture 快捷键；
- 依赖 Raycast Extension 的核心工作流；
- 强制使用 Inbox 自有账户或登录体系；
- 自建专有云后端；
- 让网络或订阅状态成为本地功能的前置条件；
- 与产品功能无关的常驻后台服务或高频遥测；
- 同步一个活动 SQLite 文件来实现多设备实时协作。

这些能力未来只有在真实使用证明有必要时才讨论，不做预埋式产品扩张。

---

# 3. 核心术语与领域模型

## 3.1 Inbox

产品名称，同时在 All View 中表示“未归属任何 Project 的 Record 集合”。

Inbox 不是普通 Project；数据层表现为 Record 没有 Project 归属。

## 3.2 Record

产品中的最小工作单元。

选择 `Record` 而不是 `Item`、`Issue`、`Todo` 或 `Entry`，原因是：

- 比 Item 更具产品含义；
- 比 Issue 和 Todo 更宽，不预设内容性质；
- 比 Entry 更容易被中文语境用户理解；
- 可自然承载未来图片、视频、日志和其他附件；
- 适合产品文档、数据库、API 和 Agent 语境。

UI 不需要在每处重复显示“Record”一词。该名称主要作为统一产品模型术语。

## 3.3 Project

Project 是 Record 的轻量分组和 Scope。

它不是：

- 页面；
- Workspace；
- 目录层级；
- 项目管理实体；
- 进度容器。

MVP 中 Project 只需要：

- Name；
- Manual Order；
- Created At；
- 稳定 ID 和同步元数据。

## 3.4 Priority

固定为：

```text
P0
P1
P2
P3
```

默认值为 `P2`。

界面只显示 P0–P3，不增加 Critical / High / Normal / Low 等文字含义。

颜色可以辅助区分，但不得成为唯一识别方式。

## 3.5 Record 状态

产品层只有：

```text
Open
Resolved
Trashed
```

关键时间记录：

- Created At；
- Resolved At；
- Deleted At；
- 为同步与冲突处理所需的系统版本信息。

## 3.6 Attachment

Attachment 是独立 Entity，并由 Record 拥有：

```text
Record 1 ─── N Attachment
```

未来支持图片、视频、音频、日志、JSON、ZIP 和其他文件。

Attachment 不是 Record 内部的一段复杂嵌套字段。它必须拥有独立 ID、类型、元数据、存储引用和生命周期。

MVP 不要求提供附件 UI，但数据与同步设计不得阻碍后续增加 Attachment。

---

# 4. 核心技术选型与架构边界

## 4.1 macOS 客户端

### 确定方案

```text
Language: Swift
Primary UI: AppKit
Animation / visual feedback: Core Animation / CALayer as needed
Local structured storage: SQLite
Cloud sync direction: CloudKit record-level sync
```

### 不选择 GPUI 的原因

GPUI 在自定义 GPU UI、CSS 式布局和 Rust 生态上有吸引力，但 Inbox 当前的主要难点不是复杂渲染，而是：

- 文本输入与输入法；
- 焦点与 Responder Chain；
- 键盘导航；
- 窗口激活；
- Dock 与 Menu Bar；
- Accessibility；
- macOS 原生行为；
- 长期 API 稳定性。

对于当前规模，AppKit 与 GPUI 在用户可感知性能上不会形成有意义差距，而 AppKit 在系统集成、包体、长期维护和可靠性上更合适。

### 不选择 Tauri 的原因

Tauri 可以降低前端开发成本，但会把核心 UI 放入 WebView 交互模型。Inbox 强调文本焦点、键盘语法、下一帧反馈和原生桌面手感，不需要浏览器布局与生态来换取额外运行时复杂度。

### SwiftUI 使用边界

核心高频界面不得以 SwiftUI-first 的方式实现。

SwiftUI 如被使用，只限于经过验证的低频、非性能关键辅助界面，例如设置页或 About。不得因“实现更快”而把 Universal Input、Scope Bar、Record List、键盘控制和快速编辑迁移为 SwiftUI 主体。

### Rust 使用边界

MVP 不引入 Rust Core。当前业务逻辑、存储和同步规模不需要跨语言层。避免为了技术偏好增加 FFI、构建和调试复杂度。

## 4.2 本地存储

### 确定方案：SQLite

每台设备拥有自己的本地 SQLite 数据库，作为即时读取、搜索、排序和写入的工作数据源。

选择 SQLite 而不是 JSON 的原因：

- 原子事务和可靠 CRUD；
- 高效增量更新；
- 排序与筛选；
- 全文检索；
- 软删除和恢复；
- Schema Migration；
- 跨语言和跨平台可读；
- 稳定、公开、长期兼容的文件格式；
- 适合作为 Agent 和脚本的数据源。

JSON 不作为主存储，因为它会逐渐要求应用自行实现索引、事务、并发、迁移、部分更新和搜索。

### 存储约束

- 只有一个逻辑 Inbox 数据集，不支持多个 Workspace；
- 每台设备拥有独立本地数据库；
- 不把活动数据库放在 iCloud Drive、Dropbox 或网络文件系统中供多设备共写；
- Agent 可自行选择 SQLite 封装库和数据访问模式；
- Schema 必须清晰、文档化、可迁移；
- 不使用阻碍第三方读取的专有数据库加密或不透明对象存储作为默认方案；
- 外部工具的安全读取方式由实现 Agent 验证，不能以开放性为由破坏活动数据库一致性。

## 4.3 本地全文搜索

MVP 必须支持全文检索。

技术方向为 SQLite FTS 或性能与开放性等价的本地索引方案。具体 tokenizer、索引刷新方式和搜索算法由 Agent 决策。

产品要求：

- 每次输入都能即时更新结果；
- 普通数据量下不出现 Loading；
- 搜索不依赖网络；
- Search 与 Create 共用 Universal Input；
- 当前 Scope 是唯一搜索范围来源；
- 排序和搜索结果必须可预测。

## 4.4 云同步

### 确定方案：CloudKit Record-level Sync

跨 macOS 和未来 iOS 的同步采用用户 iCloud 私有数据范围内的 CloudKit 记录级同步方向，优先验证 CKSyncEngine。

架构语义：

```text
Mac local SQLite      iPhone local SQLite
        │                     │
        └──── CloudKit ───────┘
```

CloudKit 是同步传输和远端副本，不是高频交互的在线数据库。

### 不采用活动数据库文件同步

不使用以下方案作为实时同步：

```text
Mac ↔ iCloud Drive 中的同一个 Inbox.sqlite ↔ iPhone
```

原因：

- 文件同步的“同时”不是同一毫秒，而是多个设备持有可写旧副本的重叠 Session；
- 即使两次编辑相隔数秒或数分钟，也可能基于同一旧版本产生冲突；
- SQLite WAL 不适合跨机器或网络文件系统共享；
- iOS 多设备使用需要记录级合并，而不是整个文件覆盖。

### iCloud Drive 的角色

未来可用于：

- Export；
- Backup；
- 用户手动归档；
- 数据迁移包；
- Agent 离线读取副本。

它不承担活动数据的多端实时同步。

## 4.5 附件同步

未来 Attachment 采用独立记录和独立资产的同步模型，CloudKit `CKAsset` 或同等官方能力是首选验证方向。

要求：

- 附件元数据与二进制内容分离；
- 列表加载 Record 时不得强制下载全部附件；
- 支持按需下载、缩略图和本地缓存；
- Resolve 不改变附件；
- Trash 保留附件；
- Restore 恢复附件关系；
- Permanent Delete 后附件才进入物理清理生命周期。

具体资产大小策略、缓存策略和清理策略由后续 Attachment 阶段验证。

## 4.6 iOS 技术边界

iOS 是明确长期计划，但不属于 macOS MVP。

未来 iOS 客户端原则：

- Swift 原生客户端；
- 使用 iOS 自然的 Touch-first 交互；
- 可选择 UIKit、SwiftUI 或组合，但不得机械复刻 macOS UI；
- 与 macOS 共享 Record、Project、Attachment 和 Sync 语义；
- 优先共享数据与同步逻辑，而不是强迫共享 UI 层。

macOS MVP 的稳定 ID、Schema、同步语义和附件关系不得依赖单设备假设。

---

# 5. 主界面信息架构

## 5.1 固定结构

```text
┌──────────────────────────────────────────────────────┐
│ Universal Input                                      │
├──────────────────────────────────────────────────────┤
│ All │ Project A │ Project B │ Project C │ … │ +      │
├──────────────────────────────────────────────────────┤
│                                                      │
│                    Record List                       │
│                                                      │
├──────────────────────────────────────────────────────┤
│ Show Resolved        Sort                       Trash│
└──────────────────────────────────────────────────────┘
```

顺序必须是：

```text
Input
↓
Scope Bar
↓
Record List
↓
Utility Area
```

不得调整为 Scope → Input → List，也不得改成左 Sidebar + 右 Content。

## 5.2 Input 在顶部的原因

Inbox 不是聊天时间流。Universal Input 控制下方结果，因此天然符合：

```text
Query
↓
Scope
↓
Results
```

顶部布局也使键盘空间模型成立：

- `↓` 从 Input 进入第一条结果；
- `↑` 从第一条 Record 返回 Input。

底部输入框会让结果方向和键盘方向冲突，因此 macOS 固定采用顶部输入。

## 5.3 Single Surface

以下行为都不产生新页面：

- Project 切换；
- 搜索；
- 创建；
- Priority 修改；
- Resolve；
- Inline Edit。

Trash 是少数允许存在的 Secondary Surface。

---

# 6. Universal Input

## 6.1 内容结构

MVP 只有一个单行 `Content` 文本字段：

- 不区分 Title / Description；
- 不支持多行；
- 不要求 Project；
- 不要求手动指定 Priority；
- 不支持 `#Project`、`!p1` 等 inline syntax。

## 6.2 初始焦点

通过以下方式打开或激活 Inbox 时，Universal Input 必须立即获得输入焦点：

- Raycast 启动应用；
- Dock 点击；
- Menu Bar 选择 Open Inbox；
- 应用已运行但窗口关闭时重新打开；
- 应用从后台激活。

首个按键不得丢失。

## 6.3 输入即搜索

Input 有内容时，当前 Record List 实时转为相关结果，不进入独立 Search Page 或 Search Mode。

Input 清空后，列表立即恢复当前 Scope 的正常浏览状态。

## 6.4 Enter 创建规则

在用户没有主动把焦点移动到现有 Record 的情况下：

```text
Enter = Create current Content
```

即使存在完全相同 Content，也允许创建。搜索只提供上下文，不阻止行动。

创建后：

- 先安全写入本地；
- UI 立即反馈；
- Input 清空；
- Focus 保持在 Input，便于连续创建；
- Record 按当前排序规则进入列表；
- 不因插入位置在视口外而强制跳动列表；
- 可提供约 2–3 秒的轻量、非阻塞反馈，允许 Undo 或定位刚创建的 Record；
- 反馈不得抢走 Input Focus，也不得要求用户确认；
- 同步在后台进行。

## 6.5 选择已有 Record

Input 有内容时：

- `↓` 将焦点移到第一条可见结果；
- 后续 `↑ / ↓` 在结果中移动；
- 第一条 Record 上按 `↑` 返回 Input；
- Record Focus 状态下按 Enter 进入 Inline Edit；
- 返回 Input 后，Enter 恢复为 Create。

## 6.6 Scope 对 Input 的约束

Input 内没有独立 Project Selector。

当前 Scope 同时决定：

- 搜索范围；
- 新建 Record 的 Project 归属。

规则：

```text
Scope = All
Search = all projects
Create Target = Inbox / unassigned

Scope = Project A
Search = Project A
Create Target = Project A
```

切换 Scope 时：

- 当前 Input 文本保持；
- Input Focus 保持；
- 搜索结果立即更新；
- Create Target 随 Scope 更新。

MVP 中搜索结果遵循 `Show Resolved` 可见性设置：默认只检索 Open；开启后同时检索当前 Scope 内的 Resolved，并保持独立分组。

---

# 7. Scope Bar 与 Project

## 7.1 Scope Bar

结构：

```text
All | Project 1 | Project 2 | … | +
```

- `All` 永远固定在第一位；
- `+` 固定在最右侧，用于 Create Project；
- Project 较多时支持横向滚动；
- 当前 Scope 必须自动保持可见；
- 上次选中的 Scope 在应用重新打开时恢复。

## 7.2 All

All 不是 Project，而是所有 Open Record 的聚合 Scope。

All View 中按以下顺序显示：

1. Inbox Group；
2. 所有 Project Group，按 Project Manual Order 排列。

示例：

```text
▼ Inbox
    Record
    Record

▼ OMotion
    Record
    Record

▶ Whisper
```

Group 支持展开/折叠，并记忆状态。

## 7.3 Project Scope

进入单个 Project 后：

- Record 平铺显示；
- 不再重复显示 Project Group Header；
- 搜索和创建都只作用于该 Project。

## 7.4 Project 顺序

Project 使用唯一的用户手动顺序。

创建 Project 时：

```text
append to current manual order
```

之后系统不根据创建时间、名称、活跃度或其他字段自动排序。

同一个顺序同时决定：

1. Scope Bar 从左到右；
2. All View Group 从上到下；
3. `⌘2…⌘0` 的快捷键映射。

用户在 Scope Bar 或 All View 拖拽 Project 时，修改的是同一个顺序来源。

## 7.5 Project CRUD

### Create

- Scope Bar 最右侧 `+`；
- All View 列表空白区域右键 → Create Project。

### Rename / Delete

- Scope Bar Project 右键；
- All View Project Group 右键。

两处能力必须一致。

### Delete Project

删除 Project 不删除 Record。

所有属于该 Project 的 Record，包括 Trash 中仍关联该 Project 的 Record，统一解除 Project 归属并进入 Inbox Group。

未来 Restore 时不会恢复到已经不存在的 Project。

---

# 8. Record List 与键盘交互

## 8.1 Record Row 展示

MVP 行内至少展示：

- Priority：P0–P3；
- Content；
- 弱化的相对创建时间，如 `2h`、`Yesterday`；
- Resolved 状态的删除线和弱化样式。

不要增加卡片化详情、Title/Description 分层或常驻操作按钮。

## 8.2 Focus 状态

Record 创建后，在 List 中有明确的 Row Focus 状态。

Row Focus 不等于文本编辑。

## 8.3 垂直导航

```text
↑ / ↓ = 在当前可见 Record 中导航
```

- 第一条 Record 按 `↑` 返回 Universal Input；
- 列表变化后 Focus 需遵循明确继承规则；
- 鼠标滚动和点击不破坏键盘继续操作的可能性。

## 8.4 Priority 快速调整

Row Focus 状态下：

```text
← = higher priority
→ = lower priority
```

顺序：

```text
P0 ← P1 ← P2 ← P3
P0 → P1 → P2 → P3
```

边界不循环。

修改后立即本地持久化，并在下一帧给出视觉反馈。

如果当前按 Priority 排序，Record 可能改变位置；Focus 应尽量继承到该 Record，避免用户丢失操作对象。具体稳定滚动策略由原型验证。

## 8.5 Inline Edit

Row Focus 状态下：

```text
Enter = enter inline editing
```

进入编辑后：

- caret 默认放到 Content 末尾；
- 用户可用系统文本快捷键或鼠标调整插入位置；
- `Enter` 提交并返回 Row Focus；
- `Esc` 放弃本次编辑并返回 Row Focus；
- 方向键、Space、Tab 等恢复标准文本编辑语义。

## 8.6 Resolve / Reopen

Row Focus 状态下：

```text
Space = Toggle Resolved
```

不使用 Tab，因为 Tab 保留给 macOS 标准 Focus Traversal 和 Accessibility。

### Show Resolved = Off

Resolve 后 Record 立即从 Open List 消失。

Focus 继承规则：

1. 原位置的下一条可见 Record；
2. 没有下一条则上一条；
3. 列表为空则 Universal Input。

### Show Resolved = On

Record 移到当前 Scope 的 Resolved Group，但 Focus 不跟随它跳到下方。Focus 继续停留在原处理流的下一条可见 Open Record。

在 Resolved Record 上按 Space 可 Reopen。

## 8.7 修改 Project 归属

必须支持通过键盘和鼠标把 Record 移动到：

- Inbox；
- 任意 Project。

采用选择器、Context Menu、Action Menu 或其他原生方式均可，由 Agent 通过原型验证。

约束：

- Universal Input 内不增加 Project Selector；
- 不使用左右方向键，因为左右键专用于 Priority；
- 不要求 inline syntax；
- 必须可在不打开详情页的情况下完成。

## 8.8 删除 Record

删除采用软删除，进入 Trash。

要求：

- 支持 Undo；
- 至少提供 Context Menu；
- 必须提供不依赖鼠标的键盘操作；
- 具体快捷键需在不冲突文本编辑、系统习惯和误操作风险的前提下通过原型确定；
- 不在 Row 上常驻显眼的 Trash Button。

---

# 9. Scope 快捷键

```text
⌘1 = All
⌘2 = Project #1
⌘3 = Project #2
...
⌘0 = Project #9
```

规则：

- 映射跟随 Project Manual Order；
- Project 拖拽后快捷键自动变化；
- 超过九个 Project 的部分通过 Scope Bar 滚动和鼠标选择；
- Scope 切换后 Input 文本与 Focus 保持；
- 当前列表立即更新；
- 不将左右方向键用于 Project 切换。

这套方案利用人类实际高频项目数量有限的事实，不为大量低频 Project 增加复杂命令系统。

---

# 10. Sorting

## 10.1 Record 排序

MVP 支持两类排序维度：

### Created Time

- Newest First；
- Oldest First。

### Priority

- P0 → P1 → P2 → P3；
- 同 Priority 下默认 Newest First。

排序设置为全局简单设置，不为每个 Project 单独保存复杂 View Configuration。

## 10.2 Resolved 排序

Open 和 Resolved 始终分组。

当前排序规则分别作用于两个组：

```text
Open
  current sort

Resolved
  same current sort
```

状态分组优先于排序，不把 Resolved 混排进 Open。

## 10.3 Project 排序

Project 与 Record 排序完全独立。

Project 只有 Manual Order，不提供名称、时间或活跃度自动排序。

---

# 11. Show Resolved

主界面 Utility Area 提供：

```text
☐ Show Resolved
```

默认关闭。

开启后：

- 当前 Scope 先显示 Open；
- 下方显示独立 Resolved Group；
- Resolved 使用删除线和弱化样式；
- All View 中每个 Project Group 内部按 Open → Resolved 组织；
- 搜索同时作用于可见的 Open 和 Resolved；
- Reopen 后 Record 回到 Open Group。

该能力是显示选项，不是新的页面。

---

# 12. Trash

## 12.1 定位

Trash 是有意提高访问成本的 Secondary Surface，用于数据恢复和永久清理，不属于日常高频处理流。

入口位于主窗口底部 Utility Area，不提供高频全局快捷键，不嵌入 Scrollbar。

## 12.2 界面

Trash 进入独立界面：

```text
← Trash

▼ Inbox
    Deleted Record

▼ Project A
    Deleted Record
```

不提供：

- Universal Input 的 Create 语义；
- Scope Bar；
- Priority 调整；
- 普通 Resolve 工作流；
- 复杂筛选。

## 12.3 能力

只需要：

- Restore；
- Delete Permanently；
- Back。

Permanent Delete 必须是明确高成本操作，并且不可被 Undo 后，应进行清楚确认。

长期 Trash 不自动过期，除非未来真实需求证明需要自动清理。

---

# 13. 应用形态与启动行为

## 13.1 Dock + Menu Bar

Inbox 同时是：

- 正常 Dock App；
- Menu Bar App。

关闭主窗口后应用继续驻留，以支持快速重新打开和菜单栏入口。只有显式 Quit 才退出。

提供可选 `Launch at Login`。

## 13.2 Raycast

MVP 不要求开发 Raycast Extension。

用户通过 Raycast 搜索 `Inbox` 并启动正常应用。Raycast 退场后，Inbox 主窗口前置且 Universal Input 已聚焦。

Inbox 必须统一处理：

- 应用未启动；
- 应用已运行但窗口关闭；
- 应用在后台；
- 应用已有主窗口。

上述场景都应表现为同一种用户体验：

```text
打开 Inbox
→ 窗口出现
→ 直接输入
```

## 13.3 Menu Bar

Menu Bar 是 Secondary Surface，可包含：

- Quick Add；
- Open Inbox；
- Quit；
- 少量非阻塞状态信息。

Quick Add 仍然采用单行 Content、默认 Inbox、默认 P2，不引入完整主窗口管理能力。

## 13.4 自有全局快捷键

MVP 不定义 Inbox 自有全局 Capture Hotkey。

原因是目标用户已经将 Raycast 作为统一启动心智，不应新增一套高频全局按键和选择分支。

---

# 14. Local-first 数据与响应路径

## 14.1 用户操作路径

所有创建、编辑、Priority、Resolve、Move、Delete 等操作遵循：

```text
User Action
↓
Local validation
↓
Durable local commit
↓
Immediate UI update
↓
Background sync / indexing / maintenance
```

不得等待：

- CloudKit；
- iCloud 网络；
- 远端确认；
- 附件上传；
- 统计更新；
- 非必要索引维护。

## 14.2 Offline

无网络或未登录 iCloud 时：

- 不要求用户注册 Inbox 专有账户；
- 所有本地功能完整可用；
- 变更进入待同步状态；
- 用户不因网络问题失去输入；
- 同步恢复后自动继续；
- 不使用阻塞性错误弹窗打断 Capture。

## 14.3 Single logical library

用户只有一个逻辑 Inbox Library。

多设备各自维护本地副本，由 CloudKit 合并。不向用户暴露 Workspace 选择和文件路径作为日常工作概念。

---

# 15. CloudKit 同步产品规则

## 15.1 同步对象

同步至少覆盖：

- Project；
- Project Manual Order；
- Record；
- Record 状态和时间；
- 未来 Attachment Metadata 和 Asset；
- 必要的 tombstone、version 和 conflict metadata。

具体 Record Type、Zone 和 Change Tracking 由 Agent 决策。

## 15.2 同步体验

正常情况下同步应保持安静：

- 不显示持续 Spinner；
- 不要求用户等待；
- 不在每次写入后弹成功提示；
- 只有持续失败、账户问题或需要用户处理的冲突才显示弱化状态。

## 15.3 冲突原则

总原则：

> **Silent when safe, lossless when not.**

### 可安全合并

不同字段的修改自动合并，例如：

- Mac 修改 Priority；
- iPhone Resolve 同一 Record。

最终同时保留两项修改，用户无需知道发生过冲突。

### 同字段冲突

当两个设备离线修改同一字段，无法确定哪一份应覆盖时：

- 不静默覆盖任何一方；
- 保存双方版本；
- 不阻断正常 Capture；
- 以弱化 Badge 或 Conflict Center 提示；
- 用户可稍后选择：
  - Keep Current；
  - Use Other；
  - Keep Both。

`Keep Both` 对 Inbox 合理，因为 Record Content 不要求唯一，可以安全创建两条 Record。

### 删除冲突

删除、恢复与另一端编辑发生冲突时，同样遵循无损原则。不得因为远端 tombstone 静默抹掉本地较新的用户内容。

具体三方合并、版本向量或时间策略属于实现决策。

## 15.4 同步错误

- 短时网络和服务错误自动重试；
- 本地写入成功即视为用户操作完成；
- 长期失败需要可诊断状态；
- 失败不得清空 Input 或丢失刚输入 Content；
- 数据修复工具可以后续增加，但 Schema 和日志从一开始应支持诊断。

---

# 16. 开放数据与 Agent Friendly

## 16.1 产品承诺

- 数据属于用户；
- 本地结构化存储可被文档化；
- 用户可以使用 SQLite 工具、脚本和 Agent 分析自己的数据；
- 不把数据锁进只有 Inbox 能理解的专有容器；
- Stable ID 和 Schema Migration 必须长期可维护；
- 未来提供标准 Export，例如 SQLite Snapshot、JSON 或 JSONL；
- 可提供 `Open Data Location`、安全只读副本或 Export 能力，具体方式由 Agent 验证。

## 16.2 外部读取与写入边界

### Read

鼓励通过文档化 Schema、只读访问或导出副本读取。

### Write

未来推荐通过稳定 External Capture Interface、CLI、URL Scheme、App Intent 或其他产品接口写入。

第三方直接修改活动数据库不作为稳定写入协议，也不承诺兼容，因为它会绕过校验、迁移、同步和冲突逻辑。

## 16.3 Raycast 与 Agent 的长期集成

未来可选：

- Raycast Add to Inbox；
- Raycast Search Inbox；
- Deep Link 到特定 Scope；
- CLI；
- Agent Tool；
- App Intent / Shortcuts；
- Inbox 数据查询工具。

这些是 Companion 能力，不改变 Inbox 作为独立专用应用的地位。

---

# 17. 性能与质量目标

“快”需要同时覆盖计算速度、输入响应和认知路径。

## 17.1 激活与输入

- Warm activation 后 Universal Input 应在约 100–150 ms 内可编辑；
- Cold launch 目标是主观瞬时，不显示不必要启动页；
- 首个按键不得丢失；
- 应用已运行时，Raycast → Inbox 的切换应接近普通原生工具的即时前置。

具体基线需在目标 Mac 上测量并记录 p50 / p95。

## 17.2 交互反馈

以下操作目标为下一显示帧反馈：

- Row Focus 移动；
- Priority 调整；
- Resolve / Reopen；
- Scope 切换；
- Input 搜索结果更新；
- Inline Edit 进入与退出。

本地持久化不得造成明显 UI 卡顿。

## 17.3 搜索与规模

- 在 10,000 条 Record 的验证数据下，普通查询目标 ≤ 50 ms；
- 输入过程中不出现常规 Loading；
- 长列表必须虚拟化或按需生成；
- 目标刷新率下滚动不因数据量明显掉帧；
- 搜索索引维护不得阻塞输入。

## 17.4 资源效率

- Idle CPU 接近 0；
- 禁止高频无意义 polling；
- Menu Bar 常驻不应持续唤醒 CPU；
- 不捆绑浏览器运行时；
- 包体和内存保持原生轻量工具水平；
- 动效只服务状态理解和直接反馈，不做长时装饰动画。

## 17.5 可靠性

- 所有写操作具有事务语义；
- Crash 后已确认成功的本地变更必须存在；
- 同步异常不损坏本地数据库；
- Migration 需要可回滚或有可靠备份策略；
- Permanent Delete 以外的误操作均应可恢复。

---

# 18. macOS MVP 功能范围

## 18.1 必须包含

- Swift + AppKit 原生应用；
- Dock App + Menu Bar；
- Launch at Login 设置；
- 主窗口关闭后驻留；
- Raycast 启动后立即 Input Focus；
- Universal Input；
- 输入即搜索；
- Enter 创建；
- All / Project Scope Bar；
- Scope Bar 横向滚动；
- Project Create / Rename / Delete / Drag Reorder；
- All View Project Group 与 Collapse State；
- Record 单行 Content；
- Priority P0–P3，默认 P2；
- Created Time；
- Open / Resolved / Trashed；
- Record CRUD；
- Inline Edit；
- Project Move；
- Created Time / Priority 排序；
- Show Resolved；
- Trash / Restore / Permanent Delete；
- Undo Delete；
- 全文搜索；
- 完整键盘交互；
- 本地 SQLite；
- CloudKit 同步基础；
- 冲突无损原则；
- 开放数据和导出边界设计；
- 未来 Attachment 与 iOS 不受阻碍的数据结构。

## 18.2 可以分阶段进入 MVP 的部分

以下能力可以在同一个 MVP 里按验证顺序后置，但不能被长期遗漏：

- Menu Bar Quick Add；
- CloudKit 冲突处理 UI；
- 安全数据导出 / 只读访问入口；
- 较完整同步诊断；
- Accessibility 细节；
- Project / Record 的全部 Context Menu；
- 最终 Record Delete 键盘映射。

---

# 19. 关键用户流程与验收

## 19.1 通过 Raycast 快速创建

```text
Raycast
→ 搜索 Inbox
→ Enter
→ Inbox 前置，Input 已聚焦
→ 输入 Content
→ Enter
→ 本地创建成功
→ Input 清空且继续聚焦
```

验收：无额外点击、无 Project 表单、无网络等待、首键不丢失。

## 19.2 在 Project 内创建

```text
⌘3 切 Project B
→ Input Focus 保持
→ 输入
→ Enter
```

验收：Record 自动属于 Project B，Input 内没有 Project Selector。

## 19.3 输入并查找已有内容

```text
输入 ABC
→ 列表即时筛选
→ ↓ 进入第一条结果
→ ↑↓ 定位
→ Enter 编辑
```

验收：未主动进入结果时 Enter 创建；主动进入结果后 Enter 编辑。

## 19.4 快速处理 Records

```text
↓ 进入列表
→ ↑↓ 导航
→ ←→ 调 Priority
→ Space Resolve
→ Focus 自动继承下一条
```

验收：整个流程不需要鼠标和复杂修饰键。

## 19.5 Project 管理

```text
Scope Bar + 创建
→ 新 Project 追加到末尾
→ 拖拽改变顺序
→ All Group 和 ⌘Number 映射同步更新
```

验收：没有第二套 Project 排序来源。

## 19.6 删除与恢复

```text
Record → Move to Trash
→ Undo 可恢复
→ Trash Secondary Surface
→ Restore 或 Delete Permanently
```

验收：普通删除不永久丢失；永久删除是高成本明确动作。

## 19.7 离线与同步

```text
断网
→ 正常创建和编辑
→ 恢复网络
→ 后台同步
```

验收：交互无阻塞，数据不丢失，不要求用户手动重试正常暂态错误。

---

# 20. 长期路线图

## Phase 0：技术与交互验证

建立最小垂直原型，验证：

- AppKit 主窗口激活和 Input Focus；
- Universal Input + List 键盘状态；
- `↑↓ / ←→ / Enter / Space / ⌘Number`；
- SQLite 写入和全文搜索；
- Raycast 启动体验；
- Project 横向 Scope Bar；
- CloudKit + 本地 SQLite 的最小记录同步。

目标不是写完整架构，而是尽快证明核心手感和最高风险路径。

## Phase 1：macOS MVP

交付完整单人 Record 闭环、基础 CloudKit 同步、Menu Bar 和开放数据基础。

## Phase 2：稳定性与开放能力

- 同步诊断和冲突中心；
- Export / Backup；
- External Capture Interface；
- CLI / URL Scheme / App Intent；
- 更完整 Accessibility；
- 性能与数据库维护工具。

## Phase 3：Attachment

- Image / Video / File；
- Attachment 独立生命周期；
- CKAsset 同步；
- 缩略图、缓存、按需下载；
- Drag / Paste Capture；
- Agent 对附件元数据的读取。

## Phase 4：iOS Exploration

将 “Inbox for iOS” 作为 Inbox 自己管理的实验 Project：

- 验证移动端 Capture；
- 验证 Scope 与 List 的 Touch-first 表达；
- 验证 Share Extension、Widget、Shortcuts 等入口；
- 不机械复用 Mac 顶部布局和键盘语法。

## Phase 5：完整 iOS 客户端

长期目标是能力上接近 macOS 完整版，但交互形式完全按 iOS 重新设计。

可能包含：

- 完整 Record 管理；
- Project Scope；
- 离线使用；
- CloudKit 同步；
- Touch-first Resolve / Priority / Edit；
- 分享、截图和附件 Capture；
- Widget / Shortcuts 等移动端原生入口。

## Phase 6：可选生态集成

在不削弱独立产品定位的前提下增加：

- Raycast Companion；
- Agent Tools；
- MCP / App Intent / Shortcuts；
- 自动化读写接口；
- 数据分析和回顾。

AI 功能只有在真实地减少操作或提高 Recall 时才进入，不因趋势而引入聊天界面或 All-in-one 工作台。

---

# 21. 关键决策记录

## 21.1 Record 命名

选择 Record，不选择 Item、Issue、Todo、Entry。

目的：宽泛、直观、可承载未来附件，并适合中文语境。

## 21.2 独立 App，而不是 Raycast-only

Raycast 是启动器，不是完整工作空间。独立 App 让用户明确切换心智，并拥有自己的交互语言和跨端路线。

## 21.3 AppKit，而不是 GPUI / Tauri / SwiftUI-first

选择系统原生能力、可预测输入、低资源、长周期稳定和 macOS 集成。Inbox 的性能瓶颈不在复杂 GPU 渲染。

## 21.4 SQLite，而不是 JSON

选择事务、全文搜索、排序、迁移、开放格式和长期可读性。JSON 只适合未来 Export，不适合作为主数据库。

## 21.5 CloudKit Record Sync，而不是 iCloud Drive Database Sync

选择记录级离线合并和多设备独立写入，避免整个数据库文件冲突。

## 21.6 Attachment 独立 Entity

Record 拥有 Attachment，但 Attachment 有独立身份、元数据、同步和生命周期，避免未来在 Record 上叠补丁。

## 21.7 Input 在顶部

Inbox 是 Query → Results，不是 Chat Timeline。顶部输入保证视觉关系和键盘方向一致。

## 21.8 Scope Bar，而不是 Sidebar

Project 是过滤 Scope，不是页面。横向 Scope Bar 更符合少量 Project 和单平面操作。

## 21.9 Space Resolve，而不是 Tab

Space 在 Row Focus 状态下切换 Resolved；Tab 保留标准焦点导航和 Accessibility。

## 21.10 Project Manual Order

创建时追加，之后完全由用户拖拽。Scope Bar、All Group 和快捷键共享同一顺序。

## 21.11 不新增全局快捷键

用户已经通过 Raycast 形成稳定启动心智。Inbox 不与现有全局快捷键系统竞争。

---

# 22. 本地执行 Agent 的工作约束

## 22.1 可以自主决策

Agent 可以自行决定：

- 代码模块与分层；
- SQLite 封装库；
- CloudKit 映射方式；
- AppKit 控件和自定义 View 的组合；
- 并发模型；
- Repository / State 管理；
- Migration 工具；
- 测试框架；
- 性能分析方式；
- Record Delete 最终快捷键；
- Move Project 的具体 Popover / Menu 设计；
- 冲突检测和三方合并算法。

## 22.2 不可自行改变

Agent 不得未经产品评审修改：

- Record / Project / Attachment 的产品语义；
- Universal Input 的 Search + Create 合一模型；
- Enter 默认 Create；
- Input → Scope → List 的结构顺序；
- 无 Sidebar 的 Single Surface；
- `↑↓ / ←→ / Enter / Space / ⌘Number` 的核心键盘语义；
- Project Manual Order；
- Local-first；
- No Silent Data Loss；
- SQLite + CloudKit 的方向；
- 独立 App 与 Raycast 的边界；
- iOS 长期计划；
- 非目标列表。

## 22.3 验证方式

高风险点优先做小型 Vertical Slice，而不是先搭建大架构：

1. 一个 Window；
2. 一个 Universal Input；
3. 一个可键盘导航的 Record List；
4. 一个本地 SQLite；
5. 一条完整 Create → Search → Edit → Priority → Resolve 链；
6. Raycast 启动与 Focus；
7. 两设备最小 CloudKit 同步。

每个 Slice 必须包含真实交互测量和用户手感验证。

---

# 23. 主要风险与验证重点

## 23.1 App 激活与 Focus

风险：Raycast 启动、后台前置、关闭窗口后恢复时首键丢失或 Focus 不稳定。

验证：覆盖 cold launch、warm launch、background、window closed、multiple displays 和 fullscreen Space。

## 23.2 Inline Edit 与键盘事件

风险：Row Focus、Text Editing、Priority 和 Resolve 的按键语义冲突。

验证：明确状态机，覆盖输入法、Accessibility 和标准文本快捷键。

## 23.3 Priority 排序后的焦点稳定

风险：左右键修改 Priority 后 Record 重排，用户失去当前对象。

验证：尝试稳定 selection、scroll anchoring 和动画反馈方案。

## 23.4 SQLite + CloudKit

风险：自定义本地 Schema 与 CloudKit Record Mapping、迁移和冲突处理复杂。

验证：先完成最小 Project + Record 双设备离线编辑、删除、恢复和冲突测试，再扩大模型。

## 23.5 开放读取与活动数据库安全

风险：允许脚本读取时影响锁、WAL 或活动写入。

验证：选择安全只读连接、Snapshot 或 Export 方案，不能简单暴露活动文件让任意工具共写。

## 23.6 附件规模

风险：视频和大文件可能影响 CloudKit 配额、缓存和初始同步。

验证：Attachment 阶段单独确定大小边界和降级策略，MVP 不提前承诺无限文件。

---

# 24. 官方技术依据

以下资料用于确认当前技术方向，具体实现仍由 Agent 在开发时核对最新版文档：

- [Apple AppKit](https://developer.apple.com/documentation/appkit)
- [Apple AppKit Views and Controls](https://developer.apple.com/documentation/appkit/views_and_controls)
- [Apple CloudKit](https://developer.apple.com/documentation/cloudkit)
- [Apple CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
- [Apple CKAsset](https://developer.apple.com/documentation/cloudkit/ckasset)
- [Apple CKError serverRecordChanged](https://developer.apple.com/documentation/cloudkit/ckerror/serverrecordchanged)
- [SQLite Single File Database and Format Stability](https://www.sqlite.org/onefile.html)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [SQLite WAL](https://www.sqlite.org/wal.html)
- [SQLite Over a Network](https://www.sqlite.org/useovernet.html)
- [Raycast Deeplinks](https://developers.raycast.com/information/lifecycle/deeplinks)

---

# 25. 一句话产品定义

> **Inbox 是一个刻意保持小而专注的个人开发 Record 工具：通用启动器负责把用户带进来，进入之后它以 Input 为第一入口，用一套极短、稳定、可形成肌肉记忆的交互，让用户完成记录、查找、整理和解决，然后离开。**

