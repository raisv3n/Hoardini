import Foundation
import HoardiniCore
import UniformTypeIdentifiers

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
    /// Only video containers AVFoundation can remux losslessly into MP4 (MPEG-TS from HLS downloads).
    static let convertible: Set<String> = ["ts", "mts", "m2ts"]

    var canConvert: Bool {
        status == .completed && !isConverting && mp4 == nil
            && destination.map { Self.convertible.contains($0.pathExtension.lowercased()) } == true
    }

    enum Kind { case video, audio, other }

    /// What the finished file is, for picking the Open button's icon and wording.
    var kind: Kind {
        guard let ext = playableURL?.pathExtension.lowercased(), !ext.isEmpty else { return request.isHLS ? .video : .other }
        if Self.convertible.contains(ext) { return .video }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    var canPause: Bool { status == .downloading }
    var isActive: Bool { status == .downloading || status == .queued }

    var etaSeconds: Double? {
        guard status == .downloading, let t = total, speed > 1 else { return nil }
        return Double(t - done) / speed
    }
}
