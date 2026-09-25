#!/bin/zsh
# Builds Pacer in Release and packages it as a drag-to-Applications disk image.
#
#     scripts/make-dmg.sh [output.dmg]
#
# The app is ad-hoc signed, not notarized. See README for what that means for people installing it.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-site/downloads/Pacer.dmg}"
work="${TMPDIR:-/tmp}/PacerDMG"
volume="Pacer"

rm -rf "$work"
mkdir -p "$work/stage/.background" "$(dirname "$out")"

xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Release -destination 'platform=macOS' build -quiet
products=$(xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
ditto "$products/Pacer.app" "$work/stage/Pacer.app"
ln -s /Applications "$work/stage/Applications"
swift scripts/render-dmg-background.swift "$work/stage/.background/background.tiff" >/dev/null

# A writable image first, so Finder can save the window layout into it.
hdiutil detach "/Volumes/$volume" -quiet 2>/dev/null || true
hdiutil create -srcfolder "$work/stage" -volname "$volume" -fs HFS+ -format UDRW -ov "$work/rw.dmg" -quiet
hdiutil attach "$work/rw.dmg" -mountpoint "/Volumes/$volume" -nobrowse -noautoopen -quiet

osascript <<EOF
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Pacer.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

chmod -Rf go-w "/Volumes/$volume" || true
sync
hdiutil detach "/Volumes/$volume" -quiet
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$out" -quiet
rm -rf "$work"
echo "Wrote $out ($(du -h "$out" | cut -f1))"
