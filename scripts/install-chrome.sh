#!/bin/bash
# Builds Hoardini from source, installs it to /Applications and opens it. On launch the app installs the
# command-line tools and registers the native-messaging host for Chrome (and Brave, Edge, Chromium, Vivaldi).
# Then load the unpacked extension it shows you (or ./extension, for working on the extension).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
open /Applications/Hoardini.app
