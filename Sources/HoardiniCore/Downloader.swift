import Foundation

public struct DownloadProgress: Sendable {
    public var done: Int64
    public var total: Int64?
    /// Set when progress is not byte-based (HLS counts segments).
    public var fractionOverride: Double?

    public var fraction: Double? {
        fractionOverride ?? total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil }
    }
}

/// Persisted next to the partial file so an interrupted download can continue.
struct DownloadState: Codable {
    var url: URL
    var length: Int64
    var validator: String?
    var segments: [Segment]
}

actor SegmentStore {
    private(set) var state: DownloadState
    private let stateURL: URL
    private var lastSave = Date.distantPast

    init(state: DownloadState, stateURL: URL) {
        self.state = state
        self.stateURL = stateURL
    }

    func segment(_ i: Int) -> Segment { state.segments[i] }
    var done: Int64 { state.segments.reduce(0) { $0 + $1.written } }

    func add(_ n: Int64, to i: Int) {
        state.segments[i].written += n
        if Date().timeIntervalSince(lastSave) > 1 { save() }
    }

    func save() {
        lastSave = Date()
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }
}

public final class Downloader: @unchecked Sendable {
    public let url: URL
    public let directory: URL
    public let connections: Int
    /// Extra request headers (e.g. Cookie, Referer, User-Agent) sent on every request.
    public let headers: [String: String]
    private let filename: String?
    private let session: URLSession
    /// Called once the destination file name is settled (before bytes are written).
    public var destinationHandler: (@Sendable (URL) -> Void)?
    private let maxRetries = 3
    private let bufferSize = 128 * 1024

    public init(url: URL, directory: URL, connections: Int = 8,
                headers: [String: String] = [:], filename: String? = nil, session: URLSession? = nil) {
        self.url = url
        self.headers = headers
        self.directory = directory
        self.connections = max(1, connections)
        self.filename = filename
        self.session = session ?? Net.session()
    }

    /// Downloads to `directory`, returning the final file URL.
    public func run(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let probe = try await Probe.run(url: url, headers: headers, session: session)
        let (finalURL, lockFD) = try claimDestination(Self.finalName(override: filename, probed: probe.filename))
        defer { Destination.release(finalURL, fd: lockFD) }
        destinationHandler?(finalURL)
        let partURL = finalURL.appendingPathExtension("part")
        let stateURL = finalURL.appendingPathExtension("hoardini")

        guard probe.acceptsRanges, let length = probe.length else {
            try await singleStream(probe: probe, partURL: partURL, finalURL: finalURL, progress: progress)
            return finalURL
        }

        let fm = FileManager.default
        var state = loadState(stateURL, matching: probe, length: length, partExists: fm.fileExists(atPath: partURL.path))
            ?? DownloadState(url: probe.finalURL, length: length, validator: probe.validator,
                             segments: SegmentPlanner.plan(length: length, count: connections))
        if state.segments.allSatisfy({ $0.written == 0 }) {
            fm.createFile(atPath: partURL.path, contents: nil)
            let h = try FileHandle(forWritingTo: partURL)
            try h.truncate(atOffset: UInt64(length))
            try h.close()
        }
        state.url = probe.finalURL

        let store = SegmentStore(state: state, stateURL: stateURL)
        await store.save()
        progress(DownloadProgress(done: await store.done, total: length))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in state.segments.indices where !state.segments[i].isDone {
                group.addTask { [self] in
                    do {
                        try await downloadSegment(i, store: store, partURL: partURL, url: probe.finalURL) {
                            progress(DownloadProgress(done: $0, total: length))
                        }
                    } catch {
                        await store.save()   // keep resume state accurate on pause/failure
                        throw error
                    }
                }
            }
            try await group.waitForAll()
        }

        let got = await store.done
        guard got == length else { throw FetchError.sizeMismatch(expected: length, got: got) }
        Quarantine.mark(partURL, source: probe.finalURL, referrer: headers["Referer"])
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: partURL, to: finalURL)
        try? fm.removeItem(at: stateURL)
        return finalURL
    }

    /// A caller-supplied name (e.g. a page title) keeps the real file's extension unless it already has it.
    static func finalName(override: String?, probed: String) -> String {
        guard let o = override.map(Probe.sanitize) else { return probed }
        let ext = (probed as NSString).pathExtension
        if ext.isEmpty || o.lowercased().hasSuffix("." + ext.lowercased()) { return o }
        return o + "." + ext
    }

    private func claimDestination(_ filename: String) throws -> (URL, Int32) {
        try Destination.claim(directory: directory, filename: filename)
    }

    private func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        for (k, v) in Net.headers(headers, for: url, origin: self.url) { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    private func loadState(_ stateURL: URL, matching probe: ProbeResult, length: Int64, partExists: Bool) -> DownloadState? {
        guard partExists, let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(DownloadState.self, from: data),
              s.length == length, s.validator == probe.validator else { return nil }
        return s
    }

    private func downloadSegment(_ i: Int, store: SegmentStore, partURL: URL, url: URL,
                                 onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        var attempt = 0
        while true {
            do {
                try await streamSegment(i, store: store, partURL: partURL, url: url, onBytes: onBytes)
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                attempt += 1
                if attempt > maxRetries { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    private func streamSegment(_ i: Int, store: SegmentStore, partURL: URL, url: URL,
                               onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let seg = await store.segment(i)
        if seg.isDone { return }
        var req = request(url)
        req.setValue("bytes=\(seg.nextOffset)-\(seg.end)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse(0) }
        guard http.statusCode == 206 else {
            throw http.statusCode == 200 ? FetchError.rangeIgnored : FetchError.badResponse(http.statusCode)
        }

        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        var offset = seg.nextOffset
        var buffer = Data()
        buffer.reserveCapacity(bufferSize)

        func flush() async throws {
            guard !buffer.isEmpty else { return }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: buffer)
            offset += Int64(buffer.count)
            await store.add(Int64(buffer.count), to: i)
            onBytes(await store.done)
            buffer.removeAll(keepingCapacity: true)
        }

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= bufferSize { try await flush() }
            if offset + Int64(buffer.count) > seg.end { break }
        }
        try await flush()
        await store.save()
    }

    private func singleStream(probe: ProbeResult, partURL: URL, finalURL: URL,
                              progress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        let fm = FileManager.default
        let (bytes, response) = try await session.bytes(for: request(probe.finalURL))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        fm.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        var buffer = Data()
        var done: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= bufferSize {
                    try handle.write(contentsOf: buffer)
                    done += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress(DownloadProgress(done: done, total: probe.length))
                }
            }
            try handle.write(contentsOf: buffer)
            done += Int64(buffer.count)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        progress(DownloadProgress(done: done, total: probe.length))
        Quarantine.mark(partURL, source: probe.finalURL, referrer: headers["Referer"])
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: partURL, to: finalURL)
    }
}
