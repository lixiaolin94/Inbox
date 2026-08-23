# 发布准备（v0.3.0）

> 工程侧已就绪；剩余步骤只有账号/设备持有人能做。产品语义以 PRD 为准，新引入的交互在 HISTORY「产品待定」等评审。

## 已完成

- Release 配置使用 Production 容器环境（entitlements 按配置取值：`$(ICLOUD_CONTAINER_ENVIRONMENT)` / `$(APS_ENVIRONMENT)`；`aps-environment` 由 provisioning profile 决定，归档用分发 profile 时为 production）。
- File ▸ Export as JSON… / Export Database Snapshot…（`VACUUM INTO`）/ Show Data in Finder。
- Settings 显示上次成功同步时间与最近错误（只读）。
- 搜索规模复查：100k 行 LIKE p95 ≤ 40 ms，保留 LIKE（HISTORY 性能基线）。
- 冲突中心：schema v4 `conflict_of` 随 CloudKit 同步，行内弱化 Conflict 标记 + 底栏 "N conflicts" 过滤 chip + 右键 Resolve Conflict ▸ Keep This / Keep Other / Keep Both（无损：放弃方进 Trash）。
- `--ui-smoke --snapshot-dir` 像素快照；Accessibility 平台默认 + 自定义控件的 label/role/value；版本 0.3.0。
- Debug 包对 Development 容器的 `--sync-probe` 双库验证通过（含 `conflictOf`）。
- App 图标：`Sources/Inbox/Resources/Assets.xcassets/AppIcon.appiconset`（用户的 iconset，16–512 @1x/@2x），`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`；构建产物含 `AppIcon.icns` + `Assets.car`。

## 发布清单

| 步骤 | 谁 |
|---|---|
| CloudKit Console 把 Development schema **Deploy to Production**（Record/Project 两个 Record Type 及索引，含 `Record.conflictOf`） | **用户** |
| 决定分发方式：Developer ID 直发（需公证）或 App Store；对应 `ENABLE_HARDENED_RUNTIME` 与签名身份 | **用户** |
| Archive（Xcode Product ▸ Archive 或 `xcodebuild archive`）并导出 | 用户/协调者 |
| /Applications 形态下人工确认 Launch at Login 注册 | 用户 |
| 用 Release 包做一次 `--sync-probe` 双库验证（需 Production schema 已部署） | 协调者 |
| 清理开发容器里的探针记录（App 内 ⌫） | 用户 |
