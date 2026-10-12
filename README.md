# Hoardini

<img src="icon.png" width="96" align="right" alt="Hoardini icon">

A fast, native macOS download manager. Hoardini splits files into parallel segments, resumes
interrupted downloads, grabs HLS (`.m3u8`) video streams and remuxes them to MP4, and hooks into
Chrome so downloads and videos can be sent to it with one click.

Free for personal use (MIT). Hoardini does not download DRM-protected streams.

## Features
- Segmented, multi-connection downloads with automatic retry and resume
- HLS stream download, with lossless remux to MP4
- Download queue with progress, speed and a menu bar item
- Chrome extension: takes over browser downloads, detects videos, adds a right-click "Download with Hoardini"
- Command-line tool: `hoardini <url> [-o dir] [-n connections] [-H "Name: value"] [--name file] [--hls]`

## Install (prebuilt)
1. Download `Hoardini.zip` from the [Releases](../../releases) page and unzip it.
2. Run `./install.sh` in the unzipped folder. It installs the app to `/Applications`, the
   command-line tools, and the Chrome native-messaging host.
3. In Chrome open `chrome://extensions`, enable **Developer mode**, click **Load unpacked**, and select
   `~/Library/Application Support/Hoardini/extension`.

The app is not notarized by Apple. `install.sh` clears the quarantine flag; if you copy the app by hand
and macOS blocks it, right-click it and choose **Open**, or run `xattr -cr /Applications/Hoardini.app`.

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
