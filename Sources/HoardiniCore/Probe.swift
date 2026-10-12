import Foundation

public struct ProbeResult: Codable, Equatable, Sendable {
    public var finalURL: URL
    public var length: Int64?
    public var acceptsRanges: Bool
    public var filename: String
    /// ETag, else Last-Modified; used to detect that the remote file changed between sessions.
    public var validator: String?
}

public enum FetchError: Error, LocalizedError {
    case badResponse(Int)
    case rangeIgnored
    case sizeMismatch(expected: Int64, got: Int64)
    case cannotWrite(String)
    case badPlaylist
    case encryptedStream
    case liveStream

    public var errorDescription: String? {
        switch self {
        case .badResponse(let c): return "Server returned HTTP \(c)"
        case .rangeIgnored: return "Server ignored the Range header"
        case .badPlaylist: return "Could not read the HLS playlist"
        case .encryptedStream: return "This stream is encrypted; Hoardini does not download protected streams"
        case .liveStream: return "Live streams are not supported"
        case .cannotWrite(let d): return "Cannot create a destination file in \(d)"
        case .sizeMismatch(let e, let g): return "Expected \(e) bytes, got \(g)"
        }
    }
}

public enum Probe {
    public static func run(url: URL, headers: [String: String] = [:], session: URLSession = .shared) async throws -> ProbeResult {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        // Response headers are available before the body; we never read the body.
        let (_, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw FetchError.badResponse(0) }

        var length: Int64?
        var ranges = false
        switch http.statusCode {
        case 206:
            if let cr = http.value(forHTTPHeaderField: "Content-Range"),
               let total = cr.split(separator: "/").last, let n = Int64(total) {
                length = n
                ranges = true
            }
        case 200:
            if http.expectedContentLength > 0 { length = http.expectedContentLength }
        default:
            throw FetchError.badResponse(http.statusCode)
        }

        let final = http.url ?? url
        return ProbeResult(
            finalURL: final,
            length: length,
            acceptsRanges: ranges,
            filename: filename(from: http, url: final),
            validator: http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
        )
    }

    static func filename(from http: HTTPURLResponse, url: URL) -> String {
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition"),
           let name = parseContentDisposition(cd) {
            return sanitize(name)
        }
        let last = url.lastPathComponent
        return sanitize(last.isEmpty || last == "/" ? "download" : last)
    }

    /// RFC 6266: prefers `filename*=UTF-8''...` over `filename="..."`.
    static func parseContentDisposition(_ value: String) -> String? {
        var plain: String?
        for part in value.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let v = String(part.dropFirst("filename*=".count))
                if let r = v.range(of: "''") {
                    let enc = String(v[r.upperBound...])
                    if let dec = enc.removingPercentEncoding { return dec }
                }
            } else if lower.hasPrefix("filename=") {
                var v = String(part.dropFirst("filename=".count))
                if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
                plain = v
            }
        }
        return plain
    }

    /// Removes control (Cc) and format (Cf) characters.
    public static func stripInvisible(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            ![.control, .format].contains($0.properties.generalCategory)
        }))
    }

    static func sanitize(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        // Control and invisible format characters (e.g. U+202E right-to-left override) can disguise the real extension.
        var cleaned = stripInvisible(decoded).replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "download" : cleaned
    }
}
