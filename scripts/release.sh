#!/bin/zsh
# Release build for direct distribution: archive → Developer ID export →
# notarize → staple → zip. Run from anywhere; output lands in build/.
#
# Signing: Developer ID comes from Xcode's cloud-managed signing via
# -allowProvisioningUpdates (no local certificate needed; verified
# 2026-08-23). One-time setup for notarization (account holder only):
#   xcrun notarytool store-credentials inbox-notary \
#     --apple-id <Apple ID> --team-id YWQ4TY4VR5 --password <app-specific password>
# (app-specific password: account.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords)
#
# Usage: scripts/release.sh            (profile name via NOTARY_PROFILE, default inbox-notary)
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-inbox-notary}"
ARCHIVE=build/Inbox.xcarchive
EXPORT=build/export
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)

rm -rf "$ARCHIVE" "$EXPORT" build/Inbox-*.zip
mkdir -p build

echo "▸ archive (Release, arm64, hardened runtime)"
xcodebuild -project Inbox.xcodeproj -scheme Inbox -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates archive | grep -E "error:|warning: .*sign|ARCHIVE (SUCCEEDED|FAILED)"

echo "▸ export with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" \
  -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
APP="$EXPORT/Inbox.app"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime" || { echo "not Developer ID signed"; exit 1; }

echo "▸ notarize ($PROFILE)"
ditto -c -k --keepParent "$APP" build/Inbox-notarize.zip
xcrun notarytool submit build/Inbox-notarize.zip --keychain-profile "$PROFILE" --wait
rm build/Inbox-notarize.zip

echo "▸ staple + verify"
xcrun stapler staple "$APP"
spctl -a -vv -t install "$APP"

ZIP="build/Inbox-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"
