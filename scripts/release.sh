#!/usr/bin/env bash
#
# Builds a notarized, stapled, universal Glossa DMG in dist/.
#
#   scripts/release.sh
#
# Prereqs (one-time): a "Developer ID Application" certificate in the keychain and a
# notarytool keychain profile (xcrun notarytool store-credentials <profile>).
# Override with GLOSSA_SIGN_IDENTITY / NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
IDENTITY="${GLOSSA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
PROFILE="${NOTARY_PROFILE:-fujifilm-notary}"
DIST="dist"
APP="$DIST/Glossa.app"
DMG="$DIST/Glossa-$VERSION.dmg"

[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found" >&2; exit 1; }
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md has no ## [$VERSION] entry" >&2; exit 1; }

echo "==> universal release build"
swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/rel-arm64 >/dev/null
swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/rel-x86_64 >/dev/null
lipo -create .build/rel-arm64/release/Glossa .build/rel-x86_64/release/Glossa -output .build/Glossa-universal
lipo -info .build/Glossa-universal

echo "==> bundle + sign ($IDENTITY)"
mkdir -p "$DIST"
GLOSSA_APP="$APP" GLOSSA_BINARY=.build/Glossa-universal GLOSSA_SIGN_IDENTITY="$IDENTITY" GLOSSA_HARDENED=1 \
    scripts/bundle.sh --release
codesign --verify --strict --deep --verbose=1 "$APP"

echo "==> notarize app"
ZIP="$DIST/Glossa-$VERSION.zip"
rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Glossa $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
rm -f "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "==> $DMG ready"
