#!/bin/bash
# Generates every icon size from Hoardini/icon.png (the single source of truth).
#   .build/icons/AppIcon.icns, menubar.png, icon-256.png   -> bundled into Hoardini.app
#   extension/icons/{16,32,48,128}.png                      -> Chrome extension
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="icon.png"
OUT=".build/icons"
SET="$OUT/AppIcon.iconset"
rm -rf "$SET"
mkdir -p "$SET" extension/icons

resize() { sips -z "$2" "$2" "$1" --out "$3" >/dev/null; }

# App icon: a full-bleed square so macOS applies its own mask (instead of wrapping our rounded
# artwork in a grey tile). Falls back to the original artwork if the helper cannot run.
if swiftc scripts/fullbleed.swift -o "$OUT/fullbleed" 2>/dev/null && "$OUT/fullbleed" "$SRC" "$OUT/fullbleed.png"; then
  APPSRC="$OUT/fullbleed.png"
else
  APPSRC="$SRC"
fi
for s in 16 32 64 128 256 512 1024; do resize "$APPSRC" "$s" "$OUT/full-$s.png"; done
cp "$OUT/full-16.png"   "$SET/icon_16x16.png"
cp "$OUT/full-32.png"   "$SET/icon_16x16@2x.png"
cp "$OUT/full-32.png"   "$SET/icon_32x32.png"
cp "$OUT/full-64.png"   "$SET/icon_32x32@2x.png"
cp "$OUT/full-128.png"  "$SET/icon_128x128.png"
cp "$OUT/full-256.png"  "$SET/icon_128x128@2x.png"
cp "$OUT/full-256.png"  "$SET/icon_256x256.png"
cp "$OUT/full-512.png"  "$SET/icon_256x256@2x.png"
cp "$OUT/full-512.png"  "$SET/icon_512x512.png"
cp "$OUT/full-1024.png" "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
resize "$SRC" 256 "$OUT/icon-256.png"   # in-window artwork keeps its own rounded shape

# Small sizes (menu bar, browser toolbar): crop the transparent margin so the artwork fills the pixels.
sips --cropToHeightWidth 1040 1040 --cropOffset 107 107 "$SRC" --out "$OUT/body.png" >/dev/null
resize "$OUT/body.png" 36 "$OUT/menubar.png"
for s in 16 32 48; do resize "$OUT/body.png" "$s" "extension/icons/$s.png"; done
resize "$SRC" 128 "extension/icons/128.png"
echo "Icons generated from $SRC"
