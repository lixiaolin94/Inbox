#!/bin/zsh
# Release build for direct distribution: archive → Developer ID export →
# notarize → staple → zip. Run from anywhere; output lands in build/.
#
# Signing: Developer ID comes from Xcode's cloud-managed signing via
# -allowProvisioningUpdates (no local certificate needed; verified
# 2026-08-23). Credentials, either:
#   - CI: ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID (App Store Connect API
#     key) — feeds both cloud signing and notarytool; or
#   - local: a notarytool keychain profile (NOTARY_PROFILE, default
#     inbox-notary), created once by the account holder:
#       xcrun notarytool store-credentials inbox-notary \
#         --apple-id <Apple ID> --team-id YWQ4TY4VR5 --password <app-specific password>
#     (app-specific password: account.apple.com ▸ Sign-In and Security)
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHIVE=build/Inbox.xcarchive
EXPORT=build/export
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  NOTARY=(--keychain-profile "${NOTARY_PROFILE:-inbox-notary}")
fi

rm -rf "$ARCHIVE" "$EXPORT" build/Inbox-*.zip
mkdir -p build

echo "▸ archive (Release, arm64, hardened runtime)"
xcodebuild -project Inbox.xcodeproj -scheme Inbox -configuration Release \
  -archivePath "$ARCHIVE" -allowProvisioningUpdates "${AUTH[@]}" archive \
  | grep -E "error:|warning: .*sign|ARCHIVE (SUCCEEDED|FAILED)"

echo "▸ export with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$EXPORT" \
  -allowProvisioningUpdates "${AUTH[@]}" | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
APP="$EXPORT/Inbox.app"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID|flags=.*runtime" || { echo "not Developer ID signed"; exit 1; }

echo "▸ notarize"
ditto -c -k --keepParent "$APP" build/Inbox-notarize.zip
xcrun notarytool submit build/Inbox-notarize.zip "${NOTARY[@]}" --wait
rm build/Inbox-notarize.zip

echo "▸ staple + verify"
xcrun stapler staple "$APP"
spctl -a -vv -t install "$APP"

ZIP="build/Inbox-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ $ZIP"
