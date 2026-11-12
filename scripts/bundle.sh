#!/usr/bin/env bash
#
# Build and wrap the SwiftPM executable into Glossa.app.
#
#   scripts/bundle.sh             # debug build  -> ./Glossa.app
#   scripts/bundle.sh --release   # release build
#   scripts/bundle.sh --open      # also (re)launch it
#   scripts/bundle.sh --install   # copy to ~/Applications and relaunch from there
#
# Signing: a stable identity keeps the Accessibility and Microphone grants across
# rebuilds (an ad-hoc signature changes every build and macOS forgets the grant).
# Uses the first "Developer ID Application" identity, then "Apple Development",
# else ad-hoc. Override with GLOSSA_SIGN_IDENTITY (use "-" for ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug; OPEN=0; INSTALL=0
for a in "$@"; do
    case "$a" in
        --release) CONFIG=release ;;
        --open) OPEN=1 ;;
        --install) INSTALL=1; OPEN=1; CONFIG=release ;;
    esac
done

if [[ -n "${GLOSSA_BINARY:-}" ]]; then
    BIN="$GLOSSA_BINARY"   # prebuilt (release.sh passes a universal binary)
else
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/Glossa"
fi
VERSION="$(cat VERSION)"
BUILD="$(date -u +%Y%m%d%H%M)"
APP="${GLOSSA_APP:-Glossa.app}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glossa"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ships inside the app so DMG and Homebrew users can set up the local server without a checkout.
cp scripts/install-server.sh "$APP/Contents/Resources/install-server.sh"
chmod +x "$APP/Contents/Resources/install-server.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Glossa</string>
    <key>CFBundleIdentifier</key><string>com.pluginslab.glossa</string>
    <key>CFBundleName</key><string>Glossa</string>
    <key>CFBundleDisplayName</key><string>Glossa</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Pluginslab. MIT License.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>Glossa records your voice while you dictate and sends it to the Whisper server you configured.</string>
    <!-- The endpoint is often plain HTTP on a LAN or tailnet address (a Whisper server on
         another machine). App Transport Security exempts 127.0.0.1 but not those, so
         without this every remote http:// endpoint fails with "requires a secure connection". -->
    <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

IDENTITY="${GLOSSA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')"
SIGN_FLAGS=(--force --sign "${IDENTITY:--}" --identifier com.pluginslab.glossa)
if [[ "${GLOSSA_HARDENED:-0}" == 1 ]]; then
    SIGN_FLAGS+=(--options runtime --timestamp --entitlements Glossa.entitlements)
fi
codesign "${SIGN_FLAGS[@]}" "$APP"
echo "==> $APP ($CONFIG, v$VERSION, signed: ${IDENTITY:-ad-hoc})"

if [[ $INSTALL == 1 ]]; then
    pkill -x Glossa 2>/dev/null || true
    sleep 0.3
    mkdir -p ~/Applications
    rm -rf ~/Applications/Glossa.app
    cp -R "$APP" ~/Applications/Glossa.app
    APP=~/Applications/Glossa.app
    echo "==> installed $APP"
elif [[ $OPEN == 1 ]]; then
    pkill -x Glossa 2>/dev/null || true
    sleep 0.3
fi
[[ $OPEN == 1 ]] && open "$APP"
exit 0
