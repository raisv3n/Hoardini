import CoreServices
import Foundation

enum Net {
    /// Session that never forwards Cookie/Authorization to a different host on redirect.
    static func session() -> URLSession {
        URLSession(configuration: .default, delegate: RedirectGuard(), delegateQueue: nil)
    }

    /// Headers safe to send to `url`: credentials only go to the host the caller supplied them for.
    static func headers(_ headers: [String: String], for url: URL, origin: URL) -> [String: String] {
        guard url.host?.lowercased() != origin.host?.lowercased() else { return headers }
        return headers.filter { !["cookie", "authorization"].contains($0.key.lowercased()) }
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if request.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

enum Quarantine {
    /// Tags a downloaded file the way browsers do, so Gatekeeper checks it before it is opened.
    static func mark(_ file: URL, source: URL, referrer: String?) {
        var props: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Hoardini",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: source,
        ]
        if let r = referrer.flatMap(URL.init(string:)) { props[kLSQuarantineOriginURLKey as String] = r }
        var values = URLResourceValues()
        values.quarantineProperties = props
        var f = file
        try? f.setResourceValues(values)
    }
}

enum Destination {
    /// Picks a destination name nobody else is using and holds an advisory lock on it.
    /// A name is usable if we get its lock and it is either a resumable download or not yet taken.
    static func claim(directory: URL, filename: String) throws -> (URL, Int32) {
        let fm = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for n in 0..<1000 {
            let name = n == 0 ? filename : "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let final = directory.appendingPathComponent(name)
            let fd = open(final.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { throw FetchError.cannotWrite(directory.path) }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                let resumable = fm.fileExists(atPath: final.appendingPathExtension("hoardini").path)
                if resumable || !fm.fileExists(atPath: final.path) { return (final, fd) }
                flock(fd, LOCK_UN)
                unlink(final.appendingPathExtension("lock").path)
            }
            close(fd)
        }
        throw FetchError.cannotWrite(directory.path)
    }

    static func release(_ url: URL, fd: Int32) {
        unlink(url.appendingPathExtension("lock").path)
        close(fd)
    }
}
