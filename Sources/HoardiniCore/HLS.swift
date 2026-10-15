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
        // Each track of a split stream goes to its own hidden temp file, then both are muxed into the .part file.
        let tracks: [(media: HLSMediaPlaylist, file: URL)] = audio.map { audio in
            [(media, Partial.trackFile(finalURL, "video", videoExt)),
             (audio, Partial.trackFile(finalURL, "audio", Self.audioExtension(audio)))]
        } ?? [(media, partURL)]

        // Pick up where a paused or interrupted download stopped, if it was the same stream.
        let stateURL = finalURL.appendingPathExtension("hoardini")
        let counts = tracks.map { $0.media.segments.count }
        let store = HLSResumeStore(url: stateURL,
                                   state: HLSState.load(stateURL, source: url, variant: variant, counts: counts)
                                       ?? HLSState(source: url, variant: variant, tracks: counts.map { HLSTrackState(segments: $0) }))
        store.save()
        let counter = SegmentCounter(total: counts.reduce(0, +), progress: progress,
                                     segments: store.state.tracks.reduce(0) { $0 + $1.done },
                                     bytes: store.state.tracks.reduce(0) { $0 + $1.bytes })
        for (k, t) in tracks.enumerated() {
            try await write(t.media, to: t.file, track: k, store: store, counter: counter)
        }
        if audio != nil {
            try? FileManager.default.removeItem(at: partURL)
            try await Remux.merge(video: tracks[0].file, audio: tracks[1].file, into: partURL)
            for t in tracks { try? FileManager.default.removeItem(at: t.file) }
        }
        Quarantine.mark(partURL, source: url, referrer: headers["Referer"])
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        try? FileManager.default.removeItem(at: stateURL)
        return finalURL
    }

    /// AVFoundation picks a reader by extension, so packed audio keeps its own (.aac, .mp3).
    static func audioExtension(_ m: HLSMediaPlaylist) -> String {
        if m.initSegment != nil { return "m4a" }
        let e = m.segments.first?.url.pathExtension.lowercased() ?? ""
        return ["aac", "mp3", "ac3", "ec3"].contains(e) ? e : "ts"
    }

    /// Appends the playlist's segments in order to `file`, continuing after the ones the store says are done.
    /// The file is kept on failure or pause so the download can resume.
    private func write(_ media: HLSMediaPlaylist, to file: URL, track k: Int, store: HLSResumeStore,
                       counter: SegmentCounter) async throws {
        var t = store.state.tracks[k]
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil
        if t.done > 0, (onDisk ?? -1) < t.bytes {
            // The track file is gone or short: this track starts over.
            counter.add(bytes: -Int(t.bytes), segments: -t.done)
            t = HLSTrackState(segments: t.segments)
        }
        if t.done == 0 { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // Bytes past the last saved segment are from a window that was cut off; drop them.
        try handle.truncate(atOffset: UInt64(t.bytes))
        try handle.seekToEnd()

        if t.done == 0, let initURL = media.initSegment {
            let d = try await fetch(initURL)
            try handle.write(contentsOf: d)
            t.bytes = Int64(d.count)
            counter.add(bytes: d.count, segments: 0)
        }
        // Download in windows of `parallel` segments, writing each window in order.
        var i = t.done
        while i < media.segments.count {
            let window = Array(media.segments[i..<min(i + parallel, media.segments.count)])
            let datas = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (k, u) in window.enumerated() { group.addTask { (k, try await self.fetch(u)) } }
                var out = [Data?](repeating: nil, count: window.count)
                for try await (k, d) in group { out[k] = d }
                return out.map { $0! }
            }
            for var d in datas {
                // fMP4 segments get fresh fragment numbers so players read past the first one.
                if media.initSegment != nil { FMP4.renumberFragments(&d, next: &t.sequence) }
                try handle.write(contentsOf: d)
                t.bytes += Int64(d.count)
            }
            i += window.count
            t.done = i
            store.state.tracks[k] = t
            store.save()
            counter.add(bytes: datas.reduce(0) { $0 + $1.count }, segments: window.count)
        }
        try handle.synchronize()
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

/// How far one track (video, audio, or the only one) of an HLS download got.
struct HLSTrackState: Codable, Equatable {
    var segments: Int              // playlist length, to tell whether the stream changed
    var done = 0                   // segments fully written, in playlist order
    var bytes: Int64 = 0           // track file length after those segments (and the init segment)
    var sequence: UInt32 = 1       // next fMP4 fragment number
}

/// Persisted as `<final name>.hoardini` so a paused or interrupted HLS download can continue.
struct HLSState: Codable, Equatable {
    var source: URL
    var variant: URL?
    var tracks: [HLSTrackState]

    /// Saved progress for this exact stream, or nil when there is none or the playlists changed.
    static func load(_ url: URL, source: URL, variant: URL?, counts: [Int]) -> HLSState? {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(HLSState.self, from: data),
              s.source == source, s.variant == variant, s.tracks.map(\.segments) == counts,
              s.tracks.allSatisfy({ (0...$0.segments).contains($0.done) && $0.bytes >= 0 && $0.sequence > 0 }) else { return nil }
        return s
    }
}

final class HLSResumeStore {
    let url: URL
    var state: HLSState

    init(url: URL, state: HLSState) {
        self.url = url
        self.state = state
    }

    func save() {
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
    }
}

/// Fragmented-MP4 (CMAF) fixups for segments that get joined into one file.
public enum FMP4 {
    /// Rewrites each top-level `moof`'s `mfhd` sequence number to `next`, `next + 1`, ...
    /// Servers that render segments independently (Tella) number every one 1; AVFoundation then
    /// reads only the first fragment of the joined file and the video comes out a few seconds long.
    public static func renumberFragments(_ data: inout Data, next: inout UInt32) {
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func box(_ at: Int, end: Int) -> (type: String, header: Int, size: Int)? {
            guard end - at >= 8 else { return nil }
            var size = UInt64(u32(at)), header = 8
            if size == 1 {
                guard end - at >= 16 else { return nil }
                size = data[at + 8..<at + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                header = 16
            } else if size == 0 {
                size = UInt64(end - at)
            }
            // Sizes come from the server: compare before converting so a huge value cannot overflow or trap.
            guard size >= UInt64(header), size <= UInt64(end - at) else { return nil }
            return (String(decoding: data[at + 4..<at + 8], as: UTF8.self), header, Int(size))
        }
        var off = data.startIndex
        while let b = box(off, end: data.endIndex) {
            if b.type == "moof" {
                var c = off + b.header
                while let child = box(c, end: off + b.size) {
                    // mfhd: header, 1-byte version, 3-byte flags, 4-byte sequence_number.
                    if child.type == "mfhd", child.size >= child.header + 8 {
                        let at = c + child.header + 4
                        withUnsafeBytes(of: next.bigEndian) { data.replaceSubrange(at..<at + 4, with: $0) }
                        next &+= 1
                        break
                    }
                    c += child.size
                }
            }
            off += b.size
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

    init(total: Int, progress: @escaping @Sendable (DownloadProgress) -> Void, segments: Int = 0, bytes: Int64 = 0) {
        self.total = max(1, total)
        self.progress = progress
        self.segments = segments
        self.bytes = bytes
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
