# 发布

分发方式：Developer ID 直发 + 公证（不上 App Store）+ Sparkle 应用内更新。
构建、签名、公证、发布全部由 GitHub Actions 完成（`.github/workflows/release.yml`）。

## 日常发版（三步）

1. `project.yml` 改 `MARKETING_VERSION`（`CURRENT_PROJECT_VERSION` 跟随它，Sparkle 版本比较依赖这一点），`xcodegen generate`，提交合并到 main；
2. `git tag v<版本>`（必须与 MARKETING_VERSION 一致，workflow 会校验）；
3. `git push origin v<版本>`。

Actions 随后：archive → Developer ID 云签名导出 → notarize → staple →
`Inbox-<版本>.zip` → `sign_update` 签名 → `appcast.xml` → GitHub Release。
应用内 Sparkle 读 `releases/latest/download/appcast.xml`（永远指向最新
Release 的 appcast，无需维护历史条目），用户经 Check for Updates… 或自动
检查拿到更新。

## 一次性密钥设置（只有账号持有人能做；私钥一律不进仓库）

1. **Sparkle EdDSA 密钥对**：

   ```bash
   curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz | tar -xJ -C /tmp/sparkle-tools
   /tmp/sparkle-tools/bin/generate_keys
   ```

   私钥存入登录 Keychain；打印出的**公钥**贴进 `project.yml` 的
   `SUPublicEDKey`（公钥可提交），`xcodegen generate` 后提交。
   导出私钥给 CI（用完即删本地文件）：

   ```bash
   /tmp/sparkle-tools/bin/generate_keys -x /tmp/sparkle_ed_key && gh secret set SPARKLE_ED_PRIVATE_KEY < /tmp/sparkle_ed_key && rm /tmp/sparkle_ed_key
   ```

2. **App Store Connect API Key**（云签名 + 公证共用一把）：
   App Store Connect ▸ 用户和访问 ▸ 集成 ▸ App Store Connect API ▸
   团队密钥 ▸ 生成（角色 **Admin**）。记下 Key ID 与 Issuer ID，下载
   `.p8`（只能下载一次）。然后：

   ```bash
   gh secret set ASC_KEY_ID --body '<Key ID>'
   ```

   ```bash
   gh secret set ASC_ISSUER_ID --body '<Issuer ID>'
   ```

   ```bash
   gh secret set ASC_KEY_P8 < ~/Downloads/AuthKey_<Key ID>.p8
   ```

3. 密钥就位后由协调者发首个正式版本；**第一个带 Sparkle 的构建需手动安装
   一次**（现装的 0.3.0 没有 updater），之后全走应用内更新。

## 本地发版（备用路径）

CI 不可用时：`scripts/release.sh`（公证走 keychain profile `inbox-notary`，
创建命令见脚本头注释）→ `SPARKLE_ED_PRIVATE_KEY=<私钥> scripts/make_appcast.sh`
→ `gh release create v<版本> build/Inbox-*.zip build/appcast.xml`。

## 遗留核对

- 对 Production 跑 `--sync-probe`：Release 包没有诊断代码，用 Debug 配置钉到
  Production 的构建：`xcodebuild -configuration Debug -derivedDataPath
  /tmp/inbox-dd-prod ICLOUD_CONTAINER_ENVIRONMENT=Production
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG CLOUDKIT_PRODUCTION' build`（已通过一次）。
- 用户：删除库里的 `probe-prod-<时间戳>` 探针记录（App 内 ⌫）；/Applications
  形态下确认 Launch at Login。
