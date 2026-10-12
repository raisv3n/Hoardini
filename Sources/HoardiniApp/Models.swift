import Foundation
import HoardiniCore

enum DownloadStatus: String, Codable {
    case queued, downloading, paused, completed, failed
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var request: JobRequest
    var status: DownloadStatus = .queued
    var destination: URL?          // final file path, known once the downloader picks a name
    var done: Int64 = 0
    var total: Int64?
    var fraction: Double?
    var error: String?
    var added = Date()
    var speed: Double = 0          // bytes/s, smoothed; not meaningful across launches
    var mp4: URL?                  // converted copy, when one exists
    var converting: Bool?
    var convertError: String?

    var displayName: String {
        if let d = destination { return d.lastPathComponent }
        if let f = request.cleanFilename { return f }
        return request.validURL?.lastPathComponent ?? request.url
    }

    /// What "Open" and "Show in Finder" should act on: the MP4 when there is one.
    var playableURL: URL? { mp4 ?? destination }
    var isConverting: Bool { converting == true }
    var canConvert: Bool {
        status == .completed && !isConverting && mp4 == nil
            && destination.map { !["mp4", "m4v", "mov"].contains($0.pathExtension.lowercased()) } == true
    }

    var canPause: Bool { !request.isHLS && status == .downloading }
    var isActive: Bool { status == .downloading || status == .queued }

    var etaSeconds: Double? {
        guard status == .downloading, let t = total, speed > 1 else { return nil }
        return Double(t - done) / speed
    }
}
