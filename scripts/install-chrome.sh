#!/bin/bash
# Builds Hoardini, installs binaries, and registers the native-messaging host for Chrome.
# Then load the unpacked extension from ./extension in chrome://extensions (Developer mode).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$HOME/Library/Application Support/Hoardini/bin"
HOSTDIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"

./scripts/build-app.sh
swift build -c release
mkdir -p "$BIN" "$HOSTDIR"
cp .build/release/hoardini .build/release/hoardini-host "$BIN/"

# Pin the extension ID: put a public key in the manifest once, derive the ID from it.
python3 -I - "$PWD/extension/manifest.json" "$BIN/hoardini-host" "$HOSTDIR/com.hoardini.host.json" <<'PY'
import sys, json, base64, hashlib, subprocess
manifest_path, host_bin, out = sys.argv[1:4]
m = json.load(open(manifest_path))
if "key" not in m:
    priv = subprocess.check_output(["openssl", "genrsa", "2048"], stderr=subprocess.DEVNULL)
    der = subprocess.check_output(["openssl", "rsa", "-pubout", "-outform", "DER"], input=priv, stderr=subprocess.DEVNULL)
    m["key"] = base64.b64encode(der).decode()
    json.dump(m, open(manifest_path, "w"), indent=2)
der = base64.b64decode(m["key"])
ext_id = "".join(chr(ord("a") + int(c, 16)) for c in hashlib.sha256(der).hexdigest()[:32])
json.dump({
    "name": "com.hoardini.host",
    "description": "Hoardini native host",
    "path": host_bin,
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://{ext_id}/"],
}, open(out, "w"), indent=2)
print("extension id:", ext_id)
PY
for b in "BraveSoftware/Brave-Browser" "Microsoft Edge" "Chromium" "Vivaldi"; do
  if [ -d "$HOME/Library/Application Support/$b" ]; then
    mkdir -p "$HOME/Library/Application Support/$b/NativeMessagingHosts"
    cp "$HOSTDIR/com.hoardini.host.json" "$HOME/Library/Application Support/$b/NativeMessagingHosts/"
  fi
done
echo "Installed. Now load $(pwd)/extension as an unpacked extension in Chrome."
