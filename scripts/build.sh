#!/bin/bash
# Builds release binaries and signs them (ad-hoc). Run as your normal user, not with sudo.
#   scripts/build.sh            -> build/release/{pantherd,panther}
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" -ne 0 ] || { echo "build.sh: run as your normal user (install.sh is the step that needs sudo)"; exit 1; }

swift build -c release --product pantherd
swift build -c release --product panther
swift build -c release --product PantherApp
BIN="$(swift build -c release --show-bin-path)"

OUT=build/release
VERSION="0.2.0"
mkdir -p "$OUT"
cp "$BIN/pantherd" "$OUT/pantherd"
cp "$BIN/panther" "$OUT/panther"

# Panther.app: menu bar only (LSUIElement), no Dock icon.
APP="$OUT/Panther.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PantherApp" "$APP/Contents/MacOS/Panther"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
PLIST="$APP/Contents/Info.plist"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleIdentifier -string com.panther.app "$PLIST"
plutil -insert CFBundleName -string Panther "$PLIST"
plutil -insert CFBundleDisplayName -string Panther "$PLIST"
plutil -insert CFBundleExecutable -string Panther "$PLIST"
plutil -insert CFBundleIconFile -string AppIcon "$PLIST"
plutil -insert CFBundlePackageType -string APPL "$PLIST"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$VERSION" "$PLIST"
plutil -insert LSMinimumSystemVersion -string 14.0 "$PLIST"
plutil -insert LSUIElement -bool true "$PLIST"
plutil -insert NSHumanReadableCopyright -string "Panther: keep working with the lid closed" "$PLIST"

# iCloud-synced folders (like the Desktop) add Finder metadata that strict code signing rejects.
xattr -cr "$APP"

# Stable identifiers + hardened runtime. Ad-hoc signing: the daemon pins each client's exact cdhash at install.
codesign --force --sign - --options runtime --identifier com.panther.daemon "$OUT/pantherd"
codesign --force --sign - --options runtime --identifier com.panther.cli "$OUT/panther"
codesign --force --sign - --options runtime --identifier com.panther.app "$APP"
codesign --verify --strict "$OUT/pantherd" "$OUT/panther"
codesign --verify --strict --deep "$APP"

echo "Built and signed:"
for f in "$OUT/pantherd" "$OUT/panther" "$APP"; do
    printf '  %-24s cdhash %s\n' "$f" "$(codesign -dvvv "$f" 2>&1 | awk -F= '/^CDHash=/{print $2}')"
done
echo "Next: sudo scripts/install.sh"
