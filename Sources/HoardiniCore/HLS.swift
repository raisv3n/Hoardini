import Foundation

/// A segment URL, or a byte range within it (EXT-X-BYTERANGE: many segments share one file).
public struct HLSSegment: Equatable {
    public var url: URL
    public var range: Range<Int64>?

    public init(url: URL, range: Range<Int64>? = nil) {
        self.url = url
        self.range = range
    }
}

public struct HLSMediaPlaylist: Equatable {
    public var segments: [HLSSegment]
    public var initSegment: HLSSegment?   // EXT-X-MAP (fragmented MP4)
    public var encrypted: Bool
    public var isLive: Bool
}

public struct HLSVariant: Equatable {
    public var bandwidth: Int
    public var url: URL
    /// GROUP-ID of the EXT-X-MEDIA audio renditions this variant plays with.
    public var audioGroup: String?
}

/// An EXT-X-MEDIA:TYPE=AUDIO entry. No URL means the audio is muxed into the variant itself.
public struct HLSAudioRendition: Equatable {
    public var groupID: String
    public var url: URL?
    public var isDefault: Bool
}

public enum HLSParsed: Equatable {
    case master(variants: [HLSVariant], audio: [HLSAudioRendition])
    case media(HLSMediaPlaylist)
}

public enum HLS {
    public static func parse(_ text: String, base: URL) -> HLSParsed {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        func resolve(_ s: String) -> URL? { URL(string: s, relativeTo: base)?.absoluteURL }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            var variants: [HLSVariant] = []
            var audio: [HLSAudioRendition] = []
            var pending: (bandwidth: Int, audioGroup: String?)?
            for l in lines {
                if l.hasPrefix("#EXT-X-STREAM-INF") {
                    pending = (Int(attribute("BANDWIDTH", in: l) ?? "") ?? 0, attribute("AUDIO", in: l))
                } else if l.hasPrefix("#EXT-X-MEDIA:"), attribute("TYPE", in: l) == "AUDIO",
                          let group = attribute("GROUP-ID", in: l) {
                    audio.append(HLSAudioRendition(groupID: group, url: attribute("URI", in: l).flatMap(resolve),
                                                   isDefault: attribute("DEFAULT", in: l) == "YES"))
                } else if !l.isEmpty, !l.hasPrefix("#"), let p = pending, let u = resolve(l) {
                    variants.append(HLSVariant(bandwidth: p.bandwidth, url: u, audioGroup: p.audioGroup))
                    pending = nil
                }
            }
            return .master(variants: variants, audio: audio)
        }

        var segs: [HLSSegment] = []
        var map: HLSSegment?
        var encrypted = false
        var ended = false
        var pendingRange: (length: Int64, offset: Int64?)?
        var rangeEnd: [URL: Int64] = [:]   // a range without "@offset" continues where the last one in that file ended
        func byteRange(_ spec: String) -> (length: Int64, offset: Int64?)? {
            let parts = spec.split(separator: "@", maxSplits: 1)
            guard let n = parts.first.flatMap({ Int64($0) }), n > 0 else { return nil }
            return (n, parts.count > 1 ? Int64(parts[1]) : nil)
        }
        func segment(_ u: URL, _ br: (length: Int64, offset: Int64?)?) -> HLSSegment {
            guard let br else { return HLSSegment(url: u) }
            let start = br.offset ?? rangeEnd[u] ?? 0
            rangeEnd[u] = start + br.length
            return HLSSegment(url: u, range: start..<(start + br.length))
        }
        for l in lines {
            if l.hasPrefix("#EXT-X-KEY") {
                if let m = attribute("METHOD", in: l), m != "NONE" { encrypted = true }
            } else if l.hasPrefix("#EXT-X-SESSION-KEY") {
                if let m = attribute("METHOD", in: l), m != "NONE" { encrypted = true }
            } else if l.hasPrefix("#EXT-X-MAP"), let u = attribute("URI", in: l).flatMap(resolve) {
                map = segment(u, attribute("BYTERANGE", in: l).flatMap(byteRange).map { ($0.length, $0.offset ?? 0) })
            } else if l.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(String(l.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if l.hasPrefix("#EXT-X-ENDLIST") {
                ended = true
            } else if !l.isEmpty, !l.hasPrefix("#"), let u = resolve(l) {
                segs.append(segment(u, pendingRange))
                pendingRange = nil
            }
        }
        return .media(HLSMediaPlaylist(segments: segs, initSegment: map, encrypted: encrypted, isLive: !ended))
    }

    /// The requested variant if the master lists it, else the highest bandwidth one.
    public static func pick(_ variants: [HLSVariant], preferred: URL?) -> HLSVariant? {
        if let preferred, let v = variants.first(where: { $0.url == preferred }) { return v }
        return variants.max(by: { $0.bandwidth < $1.bandwidth })
    }

    /// The separate audio playlist a variant needs, or nil when its audio is muxed in (or it has none).
    public static func audioURL(for variant: HLSVariant, in renditions: [HLSAudioRendition]) -> URL? {
        guard let group = variant.audioGroup else { return nil }
        let members = renditions.filter { $0.groupID == group }
        return (members.first(where: \.isDefault) ?? members.first)?.url
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
    /// A variant playlist chosen in the browser; `url` is then its master, which knows the audio track.
    private let variant: URL?
    private let session: URLSession
    private let parallel = 6
    public var destinationHandler: (@Sendable (URL) -> Void)?

    public init(url: URL, directory: URL, headers: [String: String] = [:], filename: String? = nil,
                variant: URL? = nil, session: URLSession? = nil) {
        self.url = url
        self.directory = directory
        self.headers = headers
        self.filename = filename
        self.variant = variant
        self.session = session ?? Net.session()
    }

    public func run(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        var playlistURL = url
        var media: HLSMediaPlaylist?
        var audioURL: URL?
        for _ in 0..<3 {   // master -> variant -> (rarely) nested
            switch HLS.parse(try await fetchText(playlistURL), base: playlistURL) {
            case .master(let variants, let renditions):
                guard let chosen = HLS.pick(variants, preferred: variant) else { throw FetchError.badPlaylist }
                playlistURL = chosen.url
                audioURL = HLS.audioURL(for: chosen, in: renditions) ?? audioURL
            case .media(let m):
                media = m
            }
            if media != nil { break }
        }
        // Sites like Vimeo serve video-only variants with the audio as a separate rendition.
        var audio: HLSMediaPlaylist?
        if let audioURL {
            guard case .media(let a) = HLS.parse(try await fetchText(audioURL), base: audioURL) else { throw FetchError.badPlaylist }
            audio = a
        }
        guard let media, !media.segments.isEmpty else { throw FetchError.badPlaylist }
        for m in [media, audio].compactMap({ $0 }) {
            if m.encrypted { throw FetchError.encryptedStream }
            if m.isLive { throw FetchError.liveStream }
        }
        if let a = audio, a.segments.isEmpty { audio = nil }

        let videoExt = media.initSegment != nil ? "mp4" : "ts"
        let ext = audio != nil ? "mp4" : videoExt
        var stem = filename ?? defaultName()
        // Only strip an extension we would re-add; "Lesson 1.5 intro" must stay intact.
        for known in [".ts", ".mp4", ".m4v"] where stem.lowercased().hasSuffix(known) { stem = String(stem.dropLast(known.count)) }
        let name = Probe.sanitize(stem) + "." + ext
        let (finalURL, lockFD) = try Destination.claim(directory: directory, filename: name)
        defer { Destination.release(finalURL, fd: lockFD) }
        destinationHandler?(finalURL)

        let partURL = finalURL.appendingPathExtension("part")
        let counter = SegmentCounter(total: media.segments.count + (audio?.segments.count ?? 0), progress: progress)
        if let audio {
            // Each track goes to its own hidden temp file, then both are muxed into the .part file.
            func temp(_ track: String, _ e: String) -> URL {
                directory.appendingPathComponent(".\(finalURL.lastPathComponent).\(track).\(e)")
            }
            let videoTmp = temp("video", videoExt)
            let audioTmp = temp("audio", Self.audioExtension(audio))
            defer {
                try? FileManager.default.removeItem(at: videoTmp)
                try? FileManager.default.removeItem(at: audioTmp)
            }
            try await write(media, to: videoTmp, counter: counter)
            try await write(audio, to: audioTmp, counter: counter)
            try? FileManager.default.removeItem(at: partURL)
            try await Remux.merge(video: videoTmp, audio: audioTmp, into: partURL)
        } else {
            try await write(media, to: partURL, counter: counter)
        }
        Quarantine.mark(partURL, source: url, referrer: headers["Referer"])
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        return finalURL
    }

    /// AVFoundation picks a reader by extension, so packed audio keeps its own (.aac, .mp3).
    static func audioExtension(_ m: HLSMediaPlaylist) -> String {
        if m.initSegment != nil { return "m4a" }
        let e = m.segments.first?.url.pathExtension.lowercased() ?? ""
        return ["aac", "mp3", "ac3", "ec3"].contains(e) ? e : "ts"
    }

    /// Downloads the playlist's segments in order into `file`; removes it on failure.
    private func write(_ media: HLSMediaPlaylist, to file: URL, counter: SegmentCounter) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        do {
            if let initURL = media.initSegment {
                let d = try await fetch(initURL)
                try handle.write(contentsOf: d)
                counter.add(bytes: d.count, segments: 0)
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
                for d in datas { try handle.write(contentsOf: d) }
                i += window.count
                counter.add(bytes: datas.reduce(0) { $0 + $1.count }, segments: window.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private func defaultName() -> String {
        let stem = (url.lastPathComponent as NSString).deletingPathExtension.lowercased()
        if !["", "/", "index", "playlist", "master", "main", "manifest", "stream"].contains(stem) { return stem }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "video-" + f.string(from: Date())
    }

    private func fetchText(_ u: URL) async throws -> String {
        String(decoding: try await fetch(u), as: UTF8.self)
    }

    private func fetch(_ seg: HLSSegment) async throws -> Data {
        try await fetch(seg.url, range: seg.range)
    }

    private func fetch(_ u: URL, range: Range<Int64>? = nil) async throws -> Data {
        var attempt = 0
        while true {
            do {
                var req = URLRequest(url: u)
                for (k, v) in Net.headers(headers, for: u, origin: url) { req.setValue(v, forHTTPHeaderField: k) }
                if let range { req.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range") }
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw FetchError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard let range else { return data }
                if http.statusCode == 206 {
                    guard data.count == range.count else { throw FetchError.sizeMismatch(expected: Int64(range.count), got: Int64(data.count)) }
                    return data
                }
                // Server ignored Range and sent the whole file: cut the segment out of it.
                guard data.count >= Int(range.upperBound) else { throw FetchError.rangeIgnored }
                return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                attempt += 1
                if attempt > 3 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }
}

/// Progress across every track of an HLS download, counted in segments.
final class SegmentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let progress: @Sendable (DownloadProgress) -> Void
    private var bytes: Int64 = 0
    private var segments = 0

    init(total: Int, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = max(1, total)
        self.progress = progress
    }

    func add(bytes n: Int, segments s: Int) {
        lock.lock()
        bytes += Int64(n)
        segments += s
        let p = DownloadProgress(done: bytes, total: nil, fractionOverride: Double(segments) / Double(total))
        lock.unlock()
        progress(p)
    }
}
