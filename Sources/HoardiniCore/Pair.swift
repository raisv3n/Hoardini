import Foundation

/// A video-only file and an audio-only file (DASH representations, e.g. Facebook's 720p) downloaded
/// side by side and merged into one MP4. Each half is an ordinary segmented, resumable file download.
public final class PairDownloader: @unchecked Sendable {
    public let video: URL
    public let audio: URL
    public let directory: URL
    public let headers: [String: String]
    private let filename: String?
    private let session: URLSession
    public var destinationHandler: (@Sendable (URL) -> Void)?

    public init(video: URL, audio: URL, directory: URL, headers: [String: String] = [:], filename: String? = nil,
                session: URLSession? = nil) {
        self.video = video
        self.audio = audio
        self.directory = directory
        self.headers = headers
        self.filename = filename
        self.session = session ?? Net.session()
    }

    /// The browser attached cookies for the video's host; they must not travel to a different audio host.
    private var audioHeaders: [String: String] { Net.headers(headers, for: audio, origin: video) }

    public func run(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        var stem = filename ?? video.deletingPathExtension().lastPathComponent
        for known in [".mp4", ".m4v", ".mov"] where stem.lowercased().hasSuffix(known) { stem = String(stem.dropLast(known.count)) }
        let (finalURL, lockFD) = try Destination.claim(directory: directory, filename: Probe.sanitize(stem) + ".mp4")
        defer { Destination.release(finalURL, fd: lockFD) }
        destinationHandler?(finalURL)

        // Both sizes up front, so progress runs over the two files from the start.
        async let pv = Probe.run(url: video, headers: headers, session: session)
        async let pa = Probe.run(url: audio, headers: audioHeaders, session: session)
        let sizes = try await (pv.length, pa.length)
        let total = sizes.0.flatMap { v in sizes.1.map { v + $0 } }
        let sum = PairProgress(total: total, progress: progress)

        async let v = track(video, Partial.trackFile(finalURL, "video", "mp4"), 0, sum)
        async let a = track(audio, Partial.trackFile(finalURL, "audio", "mp4"), 1, sum)
        let (videoFile, audioFile) = try await (v, a)

        let partURL = finalURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)
        try await Remux.merge(video: videoFile, audio: audioFile, into: partURL)
        Quarantine.mark(partURL, source: video, referrer: headers["Referer"])
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        for f in [videoFile, audioFile] { try? FileManager.default.removeItem(at: f) }
        return finalURL
    }

    /// Downloads one half to its hidden track file, or reuses it when an earlier run finished it
    /// (a finished track has no .hoardini resume state next to it).
    private func track(_ url: URL, _ file: URL, _ k: Int, _ sum: PairProgress) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path), !fm.fileExists(atPath: file.appendingPathExtension("hoardini").path) {
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            sum.set(k, size ?? 0)
            return file
        }
        let d = Downloader(url: url, directory: directory, headers: url == audio ? audioHeaders : headers, session: session)
        d.exactName = file.lastPathComponent
        return try await d.run { sum.set(k, $0.done) }
    }
}

final class PairProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64?
    private let progress: @Sendable (DownloadProgress) -> Void
    private var done: [Int64] = [0, 0]

    init(total: Int64?, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.progress = progress
    }

    func set(_ k: Int, _ n: Int64) {
        lock.lock()
        done[k] = n
        let p = DownloadProgress(done: done[0] + done[1], total: total)
        lock.unlock()
        progress(p)
    }
}
