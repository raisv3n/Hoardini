#!/bin/bash
# Packages the release: dist/Hoardini-<version>-macOS.zip containing only Hoardini.app.
# Installing is dragging the app into Applications; on launch it installs the command-line tools,
# the browser extension files and the native-messaging host itself (Sources/HoardiniApp/Setup.swift).
# Set UNIVERSAL=1 for an arm64 + x86_64 build; otherwise the target Mac needs this Mac's architecture.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh >/dev/null
VERSION=$(defaults read /Applications/Hoardini.app/Contents/Info CFBundleShortVersionString)
ZIP="Hoardini-$VERSION-macOS.zip"

rm -rf dist && mkdir dist
ditto -c -k --norsrc --noextattr --keepParent /Applications/Hoardini.app "dist/$ZIP"
echo "Created dist/$ZIP"
