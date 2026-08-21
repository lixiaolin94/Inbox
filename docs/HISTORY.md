# 开发史与遗留事项

> 维护规则：每个 Slice/修复合并 main 时追加时间线一行；关键决策与遗留事项随时增删。接手小任务前先扫一遍「遗留事项清单」。

## 时间线（2026-08-20 起）

| 阶段 | 范围 | 执行 | 合并点 |
|---|---|---|---|
| S1 捕获核心 | 窗口 + Universal Input + List + SQLite/FTS + Enter 创建 + 输入即搜索 + ↑↓ 焦点 | Sonnet | `a0394f9` |
| S2 键盘模型 | ←→ Priority、Space Resolve、Enter Inline Edit（含 IME 防误触）、Focus 继承 | Sonnet | `894e1e5` |
| S3a Scope 基础 | schema v2（project 表）、Scope Bar、⌘Number、主菜单、作用域化创建/搜索 | Sonnet | `749083e` |
| S3b Project 管理 | All View 分组/折叠、Rename/Delete、chip 拖拽排序、Record 移动（M/右键） | Grok 4.6 | `3574cc3` |
| S4a 排序与 Show Resolved | 三种全局排序、Resolved 分组与样式、Reopen、焦点稳定 | Grok 4.6 | `3d0a3f4` |
| S4b Trash 与 Undo | 软删除（⌫）、⌘Z Undo、Trash Secondary Surface、永久删除 | Grok 4.6 | `8ab5d1b` |
| S5 应用形态 | xcodegen 工程入库、驻留/激活、菜单栏、Launch at Login、`--ui-smoke` | Grok 4.6 | `f0c6226` |
| S6 CloudKit 同步 | CKSyncEngine、schema v3、无损冲突合并、`--sync-probe` 双库验证 | Grok 4.6 | v0.2.0 |
| fix 窗口坍缩 | 修复主窗口 fitting-size 坍缩到 28pt + ui-smoke 几何断言 | Grok 4.6 | `b31233e` |
| feat 多选与拷贝 | 列表多选（⇧↑↓/⌘A/⇧⌘点击）+ 批量 ⌫/Space/←→/Move、批量删除单步 Undo、⌘C 拷贝内容、All View 拖拽行改 Project | Fable | `30f1cbb` |
| feat R2 沉浸与多行 | 无标题沉浸窗口、iCloud Sync 菜单开关 + 账号不可用离线标签、列表多行换行（Priority/时间与首行基线对齐）、输入框超长单行尾部聚焦、拖 Record 到 Scope Bar chip | 流水线：Fable 协调/验收，Grok 4.6 执行，GPT-5.6-sol 审查 | `f780dcf` |
| feat R3 玻璃视觉与 Settings | 全窗 sidebar 材质 + fullSizeContentView、玻璃胶囊 Universal Input/Scope chip、透明行背景与行距、Record 字号偏好即时生效、Settings 窗口（⌘,：字号/Launch at Login/iCloud Sync，替代 App 菜单开关）、Titlebar 系统填充隐藏（Tahoe workaround） | 用户直连迭代（护栏文件），Fable 验收合并 | （提交时补） |

角色分工：Fable 协调/审阅/合并（不写码），Grok 4.6 xhigh 主力编码（S3b 起），Sonnet 早期编码与文档。每个合并点都经过协调者独立 build/test/冒烟。

## 关键技术决策（为什么是现在这样）

1. **中文搜索用 LIKE 而非 FTS5 MATCH**：unicode61 不切分 CJK；trigram 要求查询 ≥3 码点，排除 1–2 字中文词。`record_fts`（trigram）镜像仍完整维护，为大数据量时切换 MATCH 排名预留。实测 10k 行 LIKE ~2ms（预算 50ms）。见 RecordStore.swift 顶部注释。
2. **ListRow / ListRowIndex 是唯一的表行↔Record 映射层**：分组、Resolved 小节、导航跳过非 Record 行、焦点继承全部走它。任何列表结构改动先改这个纯函数层并补测试，禁止散落手工换算索引。
3. **焦点继承规则**（Resolve/删除后）：下一条可见 → 上一条 → 回 Input；Show Resolved 开启时只在 Open 序列上走（焦点不跟进 Resolved 组）。纯函数在 RowFocus.swift。
4. **Undo 只覆盖 Move to Trash**：窗口级 UndoManager 由 AppDelegate 路由（文本编辑时 field editor 的栈优先）。undo/redo handler 在回调开头同步注册反向动作——store 写入是异步的，不能在 completion 里注册（会开新 undo 组）。
5. **同步元数据信封含"共同祖先"**：`ck_system_fields` 存 system fields + 上次同步的字段快照。没有祖先值无法区分"两端改了不同字段"（自动合并）与"同字段冲突"（无损处理）。冲突规则表见 ConflictMerger.swift 与 docs/SCHEMA.md。
6. **窗口坍缩事故（重要教训）**：顶层 surface 四边用 Auto Layout 钉在 content view 上会让 NSWindow 持续吸附 fitting size——约束链没人提供宽度时窗口坍缩到 28pt，`setContentSize` 会被弹回，`preferredContentSize` 又会把尺寸钉死。现方案：顶层 autoresizing + 挂载后 setContentSize + `constrainFrameRect` 套 minSize。**UI 几何类改动必须在 UISmokeRunner 加断言。**
7. **xcodeproj 入库**：为了 clone 即开。project.yml 是唯一权威，改配置必须走它（含 Xcode 界面里点的签名设置——点完要回填）。

## 遗留事项清单

### 发布/分发前必须

- [ ] CloudKit 容器切 Production 并部署 schema（entitlements 中 `icloud-container-environment` 现为 Development）。
- [ ] Launch at Login 在 /Applications 安装形态下人工确认一次（开发目录 ad-hoc .app 的 SMAppService 注册可能被系统拒绝）。

### 已知小缺陷 / 打磨

- [ ] `M`（移动 Project）用硬编码 keyCode 46，非美式键盘布局可能失效；⌫/Space/方向键同理但风险低。可考虑改用 charactersIgnoringModifiers。
- [ ] Inline Edit 提交遇 DB 写入失败时编辑文本随弹窗丢弃（应保留编辑态让用户重试/复制）。
- [ ] ScopeChipButton 选中态用 CGColor 快照，系统深浅色热切换时不会自动跟随（chip 重建频繁，影响小）。
- [ ] Trash 分组组头画了 ▼ 但不可折叠（PRD 对 Trash 无折叠要求，视觉上有误导）。
- [ ] Utility 栏在 480pt 最小宽度下略挤（checkbox + Sort 弹出框 + Trash），无溢出处理。
- [ ] 已删除 Project 的折叠状态键残留在 UserDefaults（无害未清理）。
- [ ] All View 拖拽改 Project（含拖到 Scope Bar chip）无自动化覆盖（ui-smoke 不合成鼠标拖拽事件），依赖人工冒烟；drop 目标解析的纯逻辑已有单测（ListRowIndex.dropTargetGroup）。
- [ ] iCloud 离线标签只在启动时一次性检测 accountStatus——会话中途登录/登出 iCloud 不刷新；iCloud Sync 开关改动需重启生效（CKSyncEngine 无 stop API，属既定简化）。
- [ ] 开发环境 CloudKit 容器里有一条探针记录 `manual-probe-1787274876-786` 前缀类似的测试数据，同步到真实库后可在 App 内 ⌫ 删除。

### 产品待定（需要用户拍板，不要擅自改）

- [ ] All View 中 Resolve 后的"下一条 Open"会跨 Project Group 边界继承焦点——如果期望限制在组内，是产品决策。
- [ ] 从 All View 空白处右键 Create Project（PRD §7.5 提及）尚未实现，目前只有 Scope Bar 的 `+`。
- [ ] 新建 Project 后不自动切换到该 Scope（一行改动，等手感反馈）。
- [ ] 切换 iCloud 账号时本地库不隔离（保留并向新账号重放 pending）——多账号场景未定义。

### S7 计划内未做

- [ ] PRD §17.1 激活时延基线测量（warm activation 100–150ms，记录 p50/p95）。
- [ ] Accessibility 基线（VoiceOver 走查、组头/行的 accessibility 属性）。
- [ ] 数据导出入口（SQLite snapshot / JSON，PRD §16）。
- [ ] 冲突中心 / Badge UI（Phase 2；当前 Keep Both 的第二条 Record 会静默出现）。
- [ ] FTS 索引只写不读的取舍在数据量增长后复查（切 MATCH 排名搜索）。
