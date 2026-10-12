#!/bin/bash
# Packages a ready-to-install bundle for another Mac (no Swift toolchain needed there):
#   dist/Hoardini.zip  ->  Hoardini.app, bin/{hoardini,hoardini-host}, extension/, install.sh
# Set UNIVERSAL=1 for an arm64 + x86_64 build; otherwise the target Mac needs this Mac's architecture.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-icons.sh
./scripts/build-app.sh >/dev/null
if [ "${UNIVERSAL:-0}" = 1 ]; then REL=.build/apple/Products/Release; else REL=.build/release; fi

OUT="dist/Hoardini"
rm -rf dist
mkdir -p "$OUT/bin"
cp -R /Applications/Hoardini.app "$OUT/"
cp "$REL/hoardini" "$REL/hoardini-host" "$OUT/bin/"
cp -R extension "$OUT/extension"

cat > "$OUT/install.sh" <<'SH'
#!/bin/bash
# Installs Hoardini.app, the command-line tools and the Chrome native-messaging host.
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/Library/Application Support/Hoardini/bin"
HOSTDIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
EXT="$HOME/Library/Application Support/Hoardini/extension"

if [ -w /Applications ]; then cp -R Hoardini.app /Applications/; else sudo cp -R Hoardini.app /Applications/; fi
xattr -cr /Applications/Hoardini.app   # clear the download quarantine flag (app is not notarized)

mkdir -p "$BIN" "$HOSTDIR"
rm -rf "$EXT" && cp -R extension "$EXT"
cp bin/hoardini bin/hoardini-host "$BIN/"
xattr -cr "$BIN"

python3 -I - "$EXT/manifest.json" "$BIN/hoardini-host" "$HOSTDIR/com.hoardini.host.json" <<'PY'
import sys, json, base64, hashlib
manifest_path, host_bin, out = sys.argv[1:4]
der = base64.b64decode(json.load(open(manifest_path))["key"])
ext_id = "".join(chr(ord("a") + int(c, 16)) for c in hashlib.sha256(der).hexdigest()[:32])
json.dump({"name": "com.hoardini.host", "description": "Hoardini native host", "path": host_bin,
           "type": "stdio", "allowed_origins": [f"chrome-extension://{ext_id}/"]}, open(out, "w"), indent=2)
print("extension id:", ext_id)
PY
echo "Installed. In Chrome open chrome://extensions, enable Developer mode, Load unpacked: $EXT"
SH
chmod +x "$OUT/install.sh"

(cd dist && ditto -c -k --norsrc --noextattr --keepParent Hoardini Hoardini.zip)
echo "Created dist/Hoardini.zip"
