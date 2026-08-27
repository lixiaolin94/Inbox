#!/bin/zsh
# Sparkle feed for one release: signs build/Inbox-<version>.zip with the
# EdDSA key (SPARKLE_ED_PRIVATE_KEY env — the CI secret exported once via
# `generate_keys -x`) and writes build/appcast.xml describing only this
# version. SUFeedURL points at releases/latest/download/appcast.xml, so
# whichever release is latest serves its own appcast — no history needed.
set -euo pipefail
cd "$(dirname "$0")/.."
SPARKLE_VERSION=2.9.6   # keep in step with project.yml's package
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
ZIP="build/Inbox-$VERSION.zip"
[[ -f "$ZIP" ]] || { echo "missing $ZIP (run scripts/release.sh first)"; exit 1; }
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || { echo "SPARKLE_ED_PRIVATE_KEY not set"; exit 1; }

TOOLS=build/sparkle-tools
if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
  mkdir -p "$TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$TOOLS"
fi

# Output is the ready-made enclosure attributes:
#   sparkle:edSignature="…" length="…"
SIGNATURE=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$TOOLS/bin/sign_update" --ed-key-file - "$ZIP")

cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Inbox</title>
    <item>
      <title>$VERSION</title>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>https://github.com/lixiaolin94/Inbox/releases/tag/v$VERSION</link>
      <enclosure
        url="https://github.com/lixiaolin94/Inbox/releases/download/v$VERSION/Inbox-$VERSION.zip"
        $SIGNATURE
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
echo "✓ build/appcast.xml ($SIGNATURE)"
