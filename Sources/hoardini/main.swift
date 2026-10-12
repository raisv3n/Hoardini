import Foundation
import HoardiniCore

// usage: hoardini <url> [-o dir] [-n connections] [-H "Name: value"]... [--name file] [--hls]
var args = Array(CommandLine.arguments.dropFirst())

// hoardini convert <file.ts>...   : lossless remux to MP4 next to each file
if args.first == "convert" {
    var failed = false
    for path in args.dropFirst() {
        do { print(try await Remux.toMP4(URL(fileURLWithPath: path)).path) }
        catch { FileHandle.standardError.write(Data("\(path): \(error.localizedDescription)\n".utf8)); failed = true }
    }
    exit(failed ? 1 : 0)
}
var dir = FileManager.default.currentDirectoryPath
var conns = 8

func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
if let o = take("-o") { dir = o }
if let n = take("-n"), let v = Int(n) { conns = v }

var headers: [String: String] = [:]
while let h = take("-H") {
    if let c = h.firstIndex(of: ":") {
        headers[String(h[..<c]).trimmingCharacters(in: .whitespaces)] =
            String(h[h.index(after: c)...]).trimmingCharacters(in: .whitespaces)
    }
}

let name = take("--name")
var forceHLS = false
if let i = args.firstIndex(of: "--hls") { args.remove(at: i); forceHLS = true }

guard let raw = args.first, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else {
    FileHandle.standardError.write(Data("usage: hoardini <http(s) url> [-o dir] [-n connections] [-H \"Name: value\"]... [--name file] [--hls]\n".utf8))
    exit(2)
}

let start = Date()
var lastPrint = Date.distantPast
let outDir = URL(fileURLWithPath: dir)
let isHLS = forceHLS || url.pathExtension.lowercased() == "m3u8"
do {
    let onProgress: @Sendable (DownloadProgress) -> Void = { p in
        guard Date().timeIntervalSince(lastPrint) > 0.25 || p.done == p.total else { return }
        lastPrint = Date()
        let secs = max(Date().timeIntervalSince(start), 0.001)
        let mb = Double(p.done) / 1_048_576
        let pct = p.total.map { String(format: "%5.1f%%", Double(p.done) / Double($0) * 100) } ?? "  ?  "
        FileHandle.standardError.write(Data(String(format: "\r%@  %.1f MB  %.1f MB/s ", pct, mb, mb / secs).utf8))
    }
    let out: URL
    if isHLS {
        out = try await HLSDownloader(url: url, directory: outDir, headers: headers, filename: name).run(progress: onProgress)
    } else {
        out = try await Downloader(url: url, directory: outDir, connections: conns, headers: headers, filename: name)
            .run(progress: onProgress)
    }
    FileHandle.standardError.write(Data("\n".utf8))
    print(out.path)
} catch {
    FileHandle.standardError.write(Data("\nerror: \(error.localizedDescription)\n".utf8))
    exit(1)
}
