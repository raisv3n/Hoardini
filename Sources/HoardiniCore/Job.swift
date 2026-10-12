import Foundation

/// A download request as sent by the browser extension (via the native host) or typed into the app.
public struct JobRequest: Codable, Sendable, Equatable {
    public var url: String
    public var referrer: String?
    public var cookies: String?
    public var userAgent: String?
    public var kind: String?       // "file" | "hls"
    public var filename: String?

    public init(url: String, referrer: String? = nil, cookies: String? = nil, userAgent: String? = nil,
                kind: String? = nil, filename: String? = nil) {
        self.url = url
        self.referrer = referrer
        self.cookies = cookies
        self.userAgent = userAgent
        self.kind = kind
        self.filename = filename
    }

    /// Only plain http(s) URLs with a host are accepted.
    public var validURL: URL? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return u
    }

    public var isHLS: Bool { kind == "hls" || validURL?.pathExtension.lowercased() == "m3u8" }

    /// Header values containing line breaks are dropped (header injection).
    public var headers: [String: String] {
        var h: [String: String] = [:]
        for (name, value) in [("Referer", referrer), ("Cookie", cookies), ("User-Agent", userAgent)] {
            if let v = value, !v.isEmpty, !v.contains("\r"), !v.contains("\n") { h[name] = v }
        }
        return h
    }

    public var cleanFilename: String? {
        guard let f = filename else { return nil }
        let s = String(String.UnicodeScalarView(f.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(150))
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

public enum AppPaths {
    public static let bundleID = "com.hoardini.app"

    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hoardini")
    }
    public static var inbox: URL { support.appendingPathComponent("inbox") }

    public static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
