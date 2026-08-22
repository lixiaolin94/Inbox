# Inbox 数据库 Schema

本文档是 [PRD §16 开放数据承诺](../Inbox_macOS_MVP_PRD_v0.1.md)的兑现：Inbox 的本地数据格式是开放、可文档化、可被用户自己的脚本和 Agent 读取的。文档内容与 [`Sources/Inbox/RecordStore.swift`](../Sources/Inbox/Storage/RecordStore.swift)、[`Sources/Inbox/ProjectStore.swift`](../Sources/Inbox/Storage/ProjectStore.swift) 中的实际 schema 定义逐字段核对一致；如两者出现分歧，以代码为准。

数据库是单文件 SQLite，默认位置：

```
~/Library/Application Support/Inbox/inbox.sqlite
```

`--ui-smoke` 启动参数会改用系统临时目录下的一次性文件（可用 `--db-path` 覆盖），不影响这个位置（见根目录 [`README.md`](../README.md)）。CKSyncEngine 的状态序列化默认在同一目录的 `ck-sync-state.json`；若指定了 `--db-path`，则写在该路径旁的 `<db-path>.ck-sync-state`。

数据库以 WAL 模式运行（`PRAGMA journal_mode=WAL` + `synchronous=NORMAL`：写事务不再每次 fsync 主文件，读也不会被正在进行的写阻塞）。因此 Inbox 运行期间，旁边会出现 `inbox.sqlite-wal` 与 `inbox.sqlite-shm` 两个附属文件——它们是数据库的一部分，不要删除；Inbox 退出时 SQLite 会自动把 WAL 并回主文件并清理它们。外部只读工具照下文「外部读取指引」用 `?mode=ro` 打开即可，但 WAL 下的只读访问要求 `-shm` 文件可读写；做不到时（例如只拿到一份拷贝），改用 `immutable=1` 打开复制出来的快照。复制数据库时要把三个文件一起复制，或者先用 sqlite3 执行 `PRAGMA wal_checkpoint(TRUNCATE)` 把 WAL 并回主文件后再只复制 `inbox.sqlite`。

## 版本管理

Schema 版本通过 SQLite 内置的 `PRAGMA user_version` 记录，当前为 **3**。应用启动时（`RecordStore.init`）依次检查并按序执行每一个尚未应用的版本升级，每一步都在自己的事务（`BEGIN IMMEDIATE` / `COMMIT`，失败则 `ROLLBACK`）中完成，因此：

- 全新数据库会从 0 依次执行到最新版本；
- 已存在的 v1 数据库会走 v1 → v2 → v3，已有 Record 不受影响；
- 已存在的 v2 数据库只会执行 v2 → v3；
- 任意一步失败都不会留下半程状态。

## `record` 表

Record 是产品的最小工作单元（PRD §3.2）。

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | `TEXT PRIMARY KEY` | UUID 字符串（`UUID().uuidString`），创建时生成，终身不变，可作为未来同步的稳定标识。 |
| `content` | `TEXT NOT NULL` | 单行文本内容。MVP 不区分 Title/Description，不支持多行。 |
| `priority` | `INTEGER NOT NULL DEFAULT 2` | `0`–`3`，对应 P0（最高）–P3（最低）。默认 `2`（P2）。应用层通过 `←`/`→` 调整，到达边界（0 或 3）不循环。 |
| `status` | `INTEGER NOT NULL DEFAULT 0` | Record 生命周期状态：`0 = open`、`1 = resolved`、`2 = trashed`（对应 `RecordStatus` 枚举）。 |
| `project_id` | `TEXT` | 所属 Project 的 `id`；`NULL` 表示未归属任何 Project，即 All View 中的 Inbox 分组。不做外键约束——Project 被删除时，应用层会把所有指向它的 Record（包括 Trash 中的）批量置 `NULL`（见下文 `project` 表）。 |
| `created_at` | `INTEGER NOT NULL` | 创建时间，Unix 毫秒（`Int64`，非秒），创建后不再改变。 |
| `updated_at` | `INTEGER NOT NULL` | 最近一次写操作时间，Unix 毫秒。Content、Priority、Status、Project、软删除/恢复的每次写入都会刷新它。 |
| `resolved_at` | `INTEGER` | Resolve 时写入当前时间（毫秒），Reopen 时清回 `NULL`。移入 Trash 或从 Trash 恢复都不会改变这一列——Resolved 状态的 Record 被删除再恢复后仍然是 Resolved（无损恢复）。 |
| `deleted_at` | `INTEGER` | 移入 Trash 时写入当前时间（毫秒），恢复时清回 `NULL`。是软删除的标记字段，也是 Trash 列表按“最近删除优先”排序的依据。 |
| `ck_system_fields` | `BLOB` | v3 新增。CloudKit 同步信封：`NSKeyedArchiver` 编码，内含 `sys`（`CKRecord.encodeSystemFields` 的原始字节）和 `anc`（上次成功上传/下载的字段 JSON，作为三方合并的共同祖先）。`NULL` 表示这条 Record 尚未上传过。应用层通过 `CKLocalMetadata` 编解码；不要当普通 JSON/文本读。 |

索引：`idx_record_status_created` on `(status, created_at DESC)`，服务于最常见的“当前状态 + 时间排序”查询路径。

时间戳统一使用 Unix **毫秒**（而不是秒）的原因：同一秒内创建多条 Record 时仍需要可预测、确定性的排序（见 `Record.swift` 注释）。

## `project` 表

Project 是 Record 的轻量分组和 Scope（PRD §3.3），不是页面、Workspace 或层级结构。v2 迁移新增，`record.project_id` 早在 v1 就作为松散 `TEXT` 列存在，因此升级时只新建这张表，不改 `record`。

| 列 | 类型 | 说明 |
|---|---|---|
| `id` | `TEXT PRIMARY KEY` | UUID 字符串，同 `record.id` 的生成方式。 |
| `name` | `TEXT NOT NULL` | Project 名称，创建/重命名时去除首尾空白，不允许空字符串。 |
| `manual_order` | `INTEGER NOT NULL` | **唯一**的手动顺序来源。创建时取当前 `MAX(manual_order) + 1`（在事务内计算并写入，避免并发创建撞到同一个值）；此后只能通过拖拽整体重排（`reorderProjects`，把所有 Project 的 `manual_order` 一次性重写为 `0..<n` 的一个排列）。这一列同时决定三处 UI：Scope Bar 从左到右的顺序、All View 中 Project Group 从上到下的顺序、`⌘2…⌘0` 的按键映射（PRD §7.4）。不存在按名称、创建时间或活跃度的自动排序。 |
| `created_at` | `INTEGER NOT NULL` | 创建时间，Unix 毫秒。 |
| `updated_at` | `INTEGER NOT NULL` | 最近一次重命名或重排时间，Unix 毫秒。 |
| `ck_system_fields` | `BLOB` | v3 新增。与 `record.ck_system_fields` 相同的 CloudKit 信封（`sys` + `anc`），`anc` 存 Project 的 name / manual_order / 时间戳 JSON。`NULL` 表示尚未上传。 |

删除 Project（`ProjectStore.deleteProject`）不会删除 Record：同一事务内先把所有 `project_id = 该 Project` 的 Record（含 `status = trashed` 的）批量置 `project_id = NULL`，再删除 Project 行本身，使这些 Record 回到 Inbox 分组。物理删除 Project 会写入 `tombstone` 并登记 `pending_change`（`change_type = delete`）；Trash 中的 Record 只是 `status` 字段变更，走普通 upsert。

## `pending_change` 表

v3 新增。本地尚未确认到达 CloudKit 的变更。主键 `(entity, id)`，同一对象只保留最新一条意图（后写覆盖）。

| 列 | 类型 | 说明 |
|---|---|---|
| `entity` | `TEXT NOT NULL` | `record` 或 `project`。 |
| `id` | `TEXT NOT NULL` | 对应 `record.id` / `project.id`。 |
| `change_type` | `TEXT NOT NULL` | `upsert`（创建或字段更新，含移入/移出 Trash）或 `delete`（Permanent Delete）。 |

v2 → v3 升级时，已有的每一行 Record / Project 都会插入一条 `upsert`，以便首次同步把本地库上传上去。CloudKit 确认保存或删除后，对应行被删除。

## `tombstone` 表

v3 新增。只记录 **Permanent Delete**（物理删除）。Trash 是 `record.status` / `deleted_at` 的字段变更，不进这张表。

| 列 | 类型 | 说明 |
|---|---|---|
| `entity` | `TEXT NOT NULL` | `record` 或 `project`。 |
| `id` | `TEXT NOT NULL` | 被物理删除的对象 id。 |
| `deleted_at` | `INTEGER NOT NULL` | 本地删除时间，Unix 毫秒。 |

CloudKit 确认删除后清理对应行。若远端又送来一条 `updated_at` 更新的修改，tombstone 让位、本地恢复该行（无损原则）。

## `record_fts`（FTS5 镜像表）

```sql
CREATE VIRTUAL TABLE record_fts USING fts5(
    record_id UNINDEXED,
    content,
    tokenize = 'trigram'
);
```

`record_fts` 是 `record.content` 的 FTS5 trigram 镜像：每次 `INSERT`/`UPDATE` `record.content` 时，应用在同一事务内对 `record_fts` 做相应的 `INSERT`/`UPDATE`（永久删除 Record 时同步 `DELETE`），因此这张表的内容与主表严格保持一致，满足“维护 FTS5 索引”的产品要求。

**但当前 `RecordStore.search(term:)` 的实际查询路径并不使用 FTS5 `MATCH`**，而是对 `record` 表本身执行绑定参数的：

```sql
content LIKE '%term%' ESCAPE '\'
```

原因（详见 [`RecordStore.swift`](../Sources/Inbox/Storage/RecordStore.swift) 顶部注释）：

1. FTS5 默认的 `unicode61` tokenizer 完全不切分中文——连续的 CJK 文本会被当成单个 token，导致子串 `MATCH` 永远无法命中；
2. 即便换成 `trigram` tokenizer（当前建表用的就是它），查询词也必须 ≥ 3 个码点才能生效，这排除了非常常见的 1–2 个汉字搜索场景；
3. 在当前数据规模下，对 `record` 表做绑定参数的 `LIKE` 全表扫描本身足够快且对任意语言/长度都正确——实测 10,000 行、约 1,000 命中的子串查询约 2ms，10,000 行全量返回（空查询词 / 按 Priority 排序）约 5ms，都远低于 [PRD §17.3](../Inbox_macOS_MVP_PRD_v0.1.md) 的 50ms 预算。

因此现状是：正确性优先于 `MATCH` 排名能力，`record_fts` 镜像被完整维护，为将来数据规模变大后切换到基于 `MATCH` 的排名搜索预留了升级路径，但目前不是查询热路径。

## 外部读取指引

- **只读优先**：使用只读 URI 打开数据库，例如：

  ```
  sqlite3 'file:/Users/you/Library/Application Support/Inbox/inbox.sqlite?mode=ro'
  ```

  或者先把文件复制一份副本再分析（WAL 模式下要连 `-wal`/`-shm` 一起复制，见文首），两种方式都不会与正在运行的 Inbox 争抢锁。

- **不要在 Inbox 运行期间直接写入活动数据库**。这不是产品承诺的稳定写入协议：直接写库会绕过应用层的输入校验、`updated_at`/`resolved_at`/`deleted_at` 联动、FTS 镜像同步，以及未来的 CloudKit 同步与冲突处理逻辑（[PRD §16.2](../Inbox_macOS_MVP_PRD_v0.1.md)）。未来推荐的写入方式是稳定的 External Capture Interface / CLI / URL Scheme / App Intent，这些尚未实现。

- **并发注意事项**：SQLite 通过 `sqlite3_busy_timeout`（5000ms）容忍短暂的锁等待，但长时间外部写入仍可能阻塞或被 Inbox 的写入阻塞。只读连接不受影响。

## 迁移历史

| 版本 | 变更 | 对应提交 |
|---|---|---|
| v1 | 创建 `record` 表、`idx_record_status_created` 索引、`record_fts`（FTS5 trigram）虚拟表 | S1：`90fe008` add sqlite wrapper and record store with fts5 schema |
| v2 | 新增 `project` 表；`record.project_id` 沿用 v1 已有的松散 `TEXT` 列，无需改动 `record` | S3a：`44421e0` add schema v2 migration and ProjectStore |
| v3 | `record` / `project` 增加 `ck_system_fields BLOB`；新增 `pending_change`、`tombstone`；升级时为已有行登记 pending upsert | S6：CloudKit 记录级同步 |
