# Hoardini

<img src="icon.png" width="96" align="right" alt="Hoardini icon">

A fast, native macOS download manager. Hoardini splits files into parallel segments, resumes
interrupted downloads, grabs HLS (`.m3u8`) video streams and remuxes them to MP4, and hooks into
Chrome so downloads and videos can be sent to it with one click.

Free for personal use (MIT). Hoardini does not download DRM-protected streams.

## Features
- Segmented, multi-connection downloads with automatic retry and resume
- HLS stream download (including separate audio tracks and fragmented MP4), with lossless remux to MP4
- Pause and resume for every download, including video streams; quitting pauses instead of starting over
- Facebook videos: pick a quality (e.g. 720p); video and audio are downloaded and merged into one MP4
- Download queue with progress, speed and a menu bar item
- Chrome extension: takes over browser downloads, detects videos, adds a right-click "Download with Hoardini"
- Command-line tool: `hoardini <url> [-o dir] [-n connections] [-H "Name: value"] [--name file] [--hls] [--audio url]`

## Install (prebuilt)
Works on Apple Silicon and Intel Macs running macOS 13 or later.

1. Download `Hoardini-<version>-macOS.zip` from the [latest release](../../releases/latest).
2. Unzip it and drag **Hoardini.app** into **Applications**.
3. Open it. Hoardini isn't notarized by Apple (that needs a paid developer account), so macOS blocks it the
   first time: try to open it, then go to **System Settings ▸ Privacy & Security**, scroll down and click
   **Open Anyway**. Or, in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Hoardini.app
   ```
4. On first launch Hoardini installs the command-line tools and the helper that connects the browser to the
   app (for Chrome, and for Brave, Edge, Chromium, Vivaldi and Arc if they're installed), and copies the
   browser extension to `~/Library/Application Support/Hoardini/extension`. It then shows how to add the
   extension, with that folder's path already on your clipboard:
   open `chrome://extensions` (Brave: `brave://extensions`, Edge: `edge://extensions`), turn on
   **Developer mode**, click **Load unpacked**, press **⌘⇧G**, paste with **⌘V**, press Return and click
   **Select**. You can show these steps again from the menu bar icon ▸ **Set Up Browser Extension…**

You can delete the downloaded zip afterwards.

**Updating:** drag the new Hoardini.app into Applications (replace the old one) and open it once. It updates
the tools and the extension files in place. Then click the reload icon on the Hoardini extension in
`chrome://extensions`, or restart the browser.

**Extension stopped working after you deleted a download?** It was loaded from a different folder. Remove it
on the extensions page and load it again from `~/Library/Application Support/Hoardini/extension`.

## Build from source
Requires macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/raisv3n/Hoardini.git
cd Hoardini
./scripts/install-chrome.sh   # builds, installs to /Applications and opens the app (which registers the host)
```

Then load the extension as in step 4 above (or load this repo's `extension/` folder when working on it).

Other scripts: `./scripts/build-app.sh` builds and installs only the app, and
`UNIVERSAL=1 ./scripts/package.sh` creates `dist/Hoardini-<version>-macOS.zip` (arm64 + Intel). Pushing a
`v*` tag builds and publishes that zip as a GitHub release. `swift test` runs the tests.

## How it works
See [SPEC.md](SPEC.md) for the download behaviour (range requests, segmenting, resume rules).

## License
[MIT](LICENSE)
