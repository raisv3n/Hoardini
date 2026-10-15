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

1. Download `Hoardini.zip` from the [Releases](../../releases) page and unzip it.
2. Open Terminal, type `cd ` (with a space), drag the unzipped `Hoardini` folder into the window, and press
   Return. Then run:
   ```sh
   ./install.sh
   ```
   If macOS says it can't be opened or isn't permitted, run `bash install.sh` instead. The script:
   - copies the app to `/Applications` (it may ask for your password),
   - installs the command-line tools and the helper that connects Chrome to the app,
   - copies the extension to `~/Library/Application Support/Hoardini/extension`,
   - clears the "downloaded from the internet" flag so macOS doesn't block the app.
3. In Chrome open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and select
   `~/Library/Application Support/Hoardini/extension`. That folder is hidden; in the file picker press
   ⌘⇧G and paste the path.

Afterwards you can delete the downloaded zip and folder; the extension keeps working.

**Why not just drag the app into Applications?** The app would run, but the Chrome extension hands
downloads to a helper program that Chrome only allows once it is registered, which `install.sh` does.
Without it, "Download with Hoardini" silently falls back to Chrome's normal download.

The app is not notarized by Apple. If you copy it by hand and macOS blocks it, right-click it and choose
**Open**, or run `xattr -cr /Applications/Hoardini.app`.

## Build from source
Requires macOS 13+ and Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/raisv3n/Hoardini.git
cd Hoardini
./scripts/install-chrome.sh   # builds, installs to /Applications, registers the Chrome host
```

Then load the `extension/` folder as an unpacked extension (step 3 above).

Other scripts: `./scripts/build-app.sh` builds and installs only the app, and
`UNIVERSAL=1 ./scripts/package.sh` creates `dist/Hoardini.zip` (arm64 + Intel). `swift test` runs the tests.

## How it works
See [SPEC.md](SPEC.md) for the download behaviour (range requests, segmenting, resume rules).

## License
[MIT](LICENSE)
