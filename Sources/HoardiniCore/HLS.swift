import Foundation

public struct HLSMediaPlaylist: Equatable {
    public var segments: [URL]
    public var initSegment: URL?   // EXT-X-MAP (fragmented MP4)
    public var encrypted: Bool
    public var isLive: Bool
}

public enum HLSParsed: Equatable {
    case master(variants: [(bandwidth: Int, url: URL)])
    case media(HLSMediaPlaylist)

    public static func == (a: HLSParsed, b: HLSParsed) -> Bool {
        switch (a, b) {
        case (.media(let x), .media(let y)): return x == y
        case (.master(let x), .master(let y)): return x.map { "\($0.bandwidth)|\($0.url)" } == y.map { "\($0.bandwidth)|\($0.url)" }
        default: return false
        }
    }
}

public enum HLS {
    public static func parse(_ text: String, base: URL) -> HLSParsed {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func resolve(_ s: String) -> URL? { URL(string: s, relativeTo: base)?.absoluteURL }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            var variants: [(Int, URL)] = []
            var pending: Int?
            for l in lines {
                if l.hasPrefix("#EXT-X-STREAM-INF") { pending = Int(attribute("BANDWIDTH", in: l) ?? "") ?? 0 }
                else if !l.isEmpty, !l.hasPrefix("#"), let bw = pending, let u = resolve(l) { variants.append((bw, u)); pending = nil }
            }
            return .master(variants: variants)
        }

        var segs: [URL] = []
        var map: URL?
        var encrypted = false
        var ended = false
        for l in lines {
            if l.hasPrefix("#EXT-X-KEY") {
                if let m = attribute("METHOD", in: l), m != "NONE" { encrypted = true }
            } else if l.hasPrefix("#EXT-X-SESSION-KEY") {
                if let m = attribute("METHOD", in: l), m != "NONE" { encrypted = true }
            } else if l.hasPrefix("#EXT-X-MAP"), let u = attribute("URI", in: l) {
                map = resolve(u)
            } else if l.hasPrefix("#EXT-X-ENDLIST") {
                ended = true
            } else if !l.isEmpty, !l.hasPrefix("#"), let u = resolve(l) {
                segs.append(u)
            }
        }
        return .media(HLSMediaPlaylist(segments: segs, initSegment: map, encrypted: encrypted, isLive: !ended))
    }

    /// Reads `NAME=value` or `NAME="value"` out of an HLS tag line.
    static func attribute(_ name: String, in line: String) -> String? {
        guard let r = line.range(of: name + "=") else { return nil }
        // Must start an attribute, not be the tail of another name (e.g. AVERAGE-BANDWIDTH).
        if r.lowerBound > line.startIndex {
            let prev = line[line.index(before: r.lowerBound)]
            if prev != ":" && prev != "," { return attribute(name, in: String(line[r.upperBound...])) }
        }
        let rest = line[r.upperBound...]
        if rest.hasPrefix("\"") {
            let body = rest.dropFirst()
            return body.firstIndex(of: "\"").map { String(body[..<$0]) }
        }
        return String(rest.prefix { $0 != "," })
    }
}

public final class HLSDownloader: @unchecked Sendable {
    public let url: URL
    public let directory: URL
    public let headers: [String: String]
    private let filename: String?
    private let session: URLSession
    private let parallel = 6
    public var destinationHandler: (@Sendable (URL) -> Void)?

    public init(url: URL, directory: URL, headers: [String: String] = [:], filename: String? = nil, session: URLSession? = nil) {
        self.url = url
        self.directory = directory
        self.headers = headers
        self.filename = filename
        self.session = session ?? Net.session()
    }

    public func run(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        var playlistURL = url
        var media: HLSMediaPlaylist?
        for _ in 0..<3 {   // master -> variant -> (rarely) nested
            let text = String(decoding: try await fetch(playlistURL), as: UTF8.self)
            switch HLS.parse(text, base: playlistURL) {
            case .master(let variants):
                guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else { throw FetchError.badPlaylist }
                playlistURL = best.url
            case .media(let m):
                media = m
            }
            if media != nil { break }
        }
        guard let media, !media.segments.isEmpty else { throw FetchError.badPlaylist }
        if media.encrypted { throw FetchError.encryptedStream }
        if media.isLive { throw FetchError.liveStream }

        let ext = media.initSegment != nil ? "mp4" : "ts"
        var stem = filename ?? defaultName()
        // Only strip an extension we would re-add; "Lesson 1.5 intro" must stay intact.
        for known in [".ts", ".mp4", ".m4v"] where stem.lowercased().hasSuffix(known) { stem = String(stem.dropLast(known.count)) }
        let name = Probe.sanitize(stem) + "." + ext
        let (finalURL, lockFD) = try Destination.claim(directory: directory, filename: name)
        defer { Destination.release(finalURL, fd: lockFD) }
        destinationHandler?(finalURL)

        let partURL = finalURL.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        var written: Int64 = 0
        do {
            if let initURL = media.initSegment {
                let d = try await fetch(initURL)
                try handle.write(contentsOf: d)
                written += Int64(d.count)
            }
            // Download in windows of `parallel` segments, writing each window in order.
            var i = 0
            while i < media.segments.count {
                let window = Array(media.segments[i..<min(i + parallel, media.segments.count)])
                let datas = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for (k, u) in window.enumerated() { group.addTask { (k, try await self.fetch(u)) } }
                    var out = [Data?](repeating: nil, count: window.count)
                    for try await (k, d) in group { out[k] = d }
                    return out.map { $0! }
                }
                for d in datas {
                    try handle.write(contentsOf: d)
                    written += Int64(d.count)
                }
                i += window.count
                progress(DownloadProgress(done: written, total: nil,
                                          fractionOverride: Double(i) / Double(media.segments.count)))
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partURL)
            throw error
        }
        Quarantine.mark(partURL, source: url, referrer: headers["Referer"])
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        return finalURL
    }

    private func defaultName() -> String {
        let stem = (url.lastPathComponent as NSString).deletingPathExtension.lowercased()
        if !["", "/", "index", "playlist", "master", "main", "manifest", "stream"].contains(stem) { return stem }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "video-" + f.string(from: Date())
    }

    private func fetch(_ u: URL) async throws -> Data {
        var attempt = 0
        while true {
            do {
                var req = URLRequest(url: u)
                for (k, v) in Net.headers(headers, for: u, origin: url) { req.setValue(v, forHTTPHeaderField: k) }
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw FetchError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? 0)
                }
                return data
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                attempt += 1
                if attempt > 3 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }
}
