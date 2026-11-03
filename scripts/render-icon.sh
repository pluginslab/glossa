#!/usr/bin/env bash
# Renders Resources/AppIcon.svg to Resources/AppIcon-art.png (1024², headless Chrome),
# then AppIcon.png and AppIcon.icns via scripts/compose-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
"$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="$TMP/icon.png" "file://$PWD/Resources/AppIcon.svg" >/dev/null 2>&1
mv "$TMP/icon.png" Resources/AppIcon-art.png; rm -rf "$TMP"
mkdir -p .build
swift scripts/compose-icon.swift Resources/AppIcon-art.png Resources/AppIcon.png --icns
echo "wrote Resources/AppIcon.png and Resources/AppIcon.icns"
