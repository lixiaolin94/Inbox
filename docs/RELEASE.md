# 发布准备（v0.3.0）

> 工程侧已就绪；剩余步骤只有账号/设备持有人能做。产品语义以 PRD 为准，新引入的交互在 HISTORY「产品待定」等评审。

## 已完成

- Release 配置使用 Production 容器环境（entitlements 按配置取值：`$(ICLOUD_CONTAINER_ENVIRONMENT)` / `$(APS_ENVIRONMENT)`；`aps-environment` 由 provisioning profile 决定，归档用分发 profile 时为 production）。
- File ▸ Export as JSON… / Export Database Snapshot…（`VACUUM INTO`）/ Show Data in Finder。
- Settings 显示上次成功同步时间与最近错误（只读）。
- 搜索规模复查：100k 行 LIKE p95 ≤ 40 ms，保留 LIKE（HISTORY 性能基线）。
- 冲突中心：schema v4 `conflict_of` 随 CloudKit 同步，行内弱化 Conflict 标记 + 底栏 "N conflicts" 过滤 chip + 右键 Resolve Conflict ▸ Keep This / Keep Other / Keep Both（无损：放弃方进 Trash）。
- `--ui-smoke --snapshot-dir` 像素快照；Accessibility 平台默认 + 自定义控件的 label/role/value；版本 0.3.0。
- 2026-08-23：Production schema 已部署（Record 15 字段含 `conflictOf`——Console 里手动补的，CloudKit 只在首次写非空值时建字段；Project 10 字段；索引与安全角色）。环境切换重传已实现并在真实库上完成（12 条记录 + 3 个 Project 重新上传，`lastSyncEnvironment = production`）。Production 双库 `--sync-probe` 通过。
- App 图标：`Sources/Inbox/Resources/Assets.xcassets/AppIcon.appiconset`（用户的 iconset，16–512 @1x/@2x），`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`；构建产物含 `AppIcon.icns` + `Assets.car`。

## 发布清单

| 步骤 | 谁 |
|---|---|
| 决定分发方式：Developer ID 直发（需公证）或 App Store；对应 `ENABLE_HARDENED_RUNTIME` 与签名身份 | **用户** |
| Archive（Xcode Product ▸ Archive 或 `xcodebuild archive`）并导出 | 用户/协调者 |
| /Applications 形态下人工确认 Launch at Login 注册 | 用户 |
| 对 Production 跑 `--sync-probe`：Release 包没有诊断代码，要用 Debug 配置钉到 Production 的构建：`xcodebuild -configuration Debug -derivedDataPath /tmp/inbox-dd-prod ICLOUD_CONTAINER_ENVIRONMENT=Production 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG CLOUDKIT_PRODUCTION' build` | 协调者（已通过一次） |
| 清理探针记录：Production 里有一条 `probe-prod-<时间戳>`（已同步进本地库，App 内 ⌫ 删除即可）；Development 容器可整体忽略 | 用户 |
