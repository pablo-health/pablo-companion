#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <Pablo.app> <output.dmg> <artwork.png>" >&2
  exit 64
fi

app_path="$1"
output_path="$2"
artwork_path="$3"

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 66
fi

work_dir="$(mktemp -d)"
trap 'hdiutil detach "$work_dir/mount" -quiet 2>/dev/null || true; rm -rf "$work_dir"' EXIT

mkdir -p "$work_dir/source/.background" "$work_dir/mount"
cp -R "$app_path" "$work_dir/source/Pablo.app"
ln -s /Applications "$work_dir/source/Applications"
swift "$(dirname "$0")/create-macos-dmg.swift" \
  "$artwork_path" "$work_dir/source/.background/background.png"

hdiutil create -quiet -volname "Pablo" -srcfolder "$work_dir/source" \
  -ov -format UDRW "$work_dir/Pablo-rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen \
  -mountpoint "$work_dir/mount" "$work_dir/Pablo-rw.dmg"

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "Pablo"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {120, 120, 780, 540}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 104
    set text size of theViewOptions to 13
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "Pablo.app" of container window to {165, 225}
    set position of item "Applications" of container window to {495, 225}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

hdiutil detach "$work_dir/mount" -quiet
hdiutil convert -quiet "$work_dir/Pablo-rw.dmg" -format UDZO \
  -imagekey zlib-level=9 -o "$output_path"

