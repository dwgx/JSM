#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  build_installer_dmg.sh -a /path/to/JSM.app -o /path/to/output.dmg [-v "JSM Installer"]

This creates a drag-to-Applications installer DMG.
EOF
}

APP_PATH=""
OUT_DMG=""
VOL_NAME="JSM Installer"

while getopts ":a:o:v:h" opt; do
  case "$opt" in
    a) APP_PATH="$OPTARG" ;;
    o) OUT_DMG="$OPTARG" ;;
    v) VOL_NAME="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Missing value for -$OPTARG" >&2
      usage
      exit 1
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$APP_PATH" || -z "$OUT_DMG" ]]; then
  usage
  exit 1
fi

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

APP_NAME="$(basename "$APP_PATH")"
OUT_DMG="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT_DMG")"
OUT_DIR="$(dirname "$OUT_DMG")"
mkdir -p "$OUT_DIR"

WORK_DIR="$(mktemp -d /tmp/jsm-dmg.XXXXXX)"
STAGE_DIR="$WORK_DIR/stage"
RW_DMG="$WORK_DIR/temp-rw.dmg"

cleanup() {
  if mount | grep -q "/Volumes/$VOL_NAME"; then
    hdiutil detach "/Volumes/$VOL_NAME" -quiet || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
cat > "$STAGE_DIR/INSTALL.txt" <<'EOF'
Install:
1. Drag JSM.app into Applications.
2. Open JSM from Applications.
EOF

hdiutil create -size 200m -fs HFS+ -volname "$VOL_NAME" -srcfolder "$STAGE_DIR" -format UDRW "$RW_DMG" -quiet

DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="/Volumes/$VOL_NAME"

if [[ -z "$DEVICE" ]]; then
  echo "Failed to mount DMG." >&2
  exit 1
fi

# Configure Finder window layout to present a clear drag-to-install page.
if ! osascript - "$VOL_NAME" "$APP_NAME" <<'OSA'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk volName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {140, 120, 900, 560}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 120
      set text size of opts to 14
      set position of item appName of container window to {180, 220}
      set position of item "Applications" of container window to {560, 220}
      close
      open
      update without registering applications
      delay 1
    end tell
  end tell
end run
OSA
then
  echo "Warning: Finder layout script failed. DMG is still usable." >&2
fi

sync
hdiutil detach "$DEVICE" -quiet || hdiutil detach "$MOUNT_POINT" -force -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" -quiet

echo "Created installer DMG: $OUT_DMG"
