# Hoardini — behaviour spec (clean-room)

Sources: public HTTP standards (RFC 9110 range requests, RFC 6266 Content-Disposition)
and generally documented download-manager behaviour. No decompiled or disassembled
code from any existing product is used or referenced.

## v0 scope: download core
1. **Probe** a URL with `GET` + `Range: bytes=0-0` (works on servers that reject HEAD).
   - `206` + `Content-Range: bytes 0-0/N` → ranges supported, length N.
   - `200` → no range support; length from `Content-Length` if present.
2. **Filename**: `Content-Disposition` (`filename*` preferred), else last path component
   of the final (post-redirect) URL; sanitised.
3. **Segment**: split length into up to N contiguous byte ranges (default 8, min 256 KiB each).
4. **Download** each segment concurrently with `Range`, writing at its offset in a
   preallocated `<name>.part` file.
5. **Resume**: progress persisted to `<name>.hoardini` (JSON: url, length, validator, per-segment
   bytes written). Resume only if URL, length and validator (ETag / Last-Modified) still match.
6. **Retry** a failed segment up to 3 times with backoff, continuing from its written offset.
7. **Finish**: rename `.part` → final name, delete sidecar.
8. No range support → single-stream download, no resume.

## Later
Queue + scheduler, speed limits, SwiftUI app, Safari/Chrome extension via native messaging,
site-specific auth/cookies, media-stream detection, checksum verification.
