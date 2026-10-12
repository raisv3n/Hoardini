import AVFoundation
import Foundation

public enum RemuxError: Error, LocalizedError {
    case unreadable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "This file has no readable video or audio"
        case .failed(let m): return "Conversion failed: \(m)"
        }
    }
}

/// Copies the audio/video streams into an MP4 container without re-encoding (fast, lossless).
public enum Remux {
    public static func toMP4(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable), !(try await asset.load(.tracks)).isEmpty else {
            throw RemuxError.unreadable
        }

        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let (final, lockFD) = try Destination.claim(directory: dir, filename: base + ".mp4")
        defer { Destination.release(final, fd: lockFD) }

        let tmp = final.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RemuxError.failed("passthrough export is not available for this file")
        }
        export.outputURL = tmp
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true   // index at the front: instant seeking

        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw RemuxError.failed(export.error?.localizedDescription ?? "unknown error")
        }
        try FileManager.default.moveItem(at: tmp, to: final)
        return final
    }

    /// Combines a video-only and an audio-only file into one MP4, without re-encoding.
    public static func merge(video: URL, audio: URL, into output: URL) async throws {
        let v = AVURLAsset(url: video), a = AVURLAsset(url: audio)
        guard let vt = try await v.loadTracks(withMediaType: .video).first,
              let at = try await a.loadTracks(withMediaType: .audio).first else { throw RemuxError.unreadable }

        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RemuxError.failed("could not combine the video and audio tracks")
        }
        // Both tracks start at zero; MPEG-TS timestamps often begin well past it.
        try cv.insertTimeRange(try await vt.load(.timeRange), of: vt, at: .zero)
        try ca.insertTimeRange(try await at.load(.timeRange), of: at, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
            throw RemuxError.failed("passthrough export is not available for this file")
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw RemuxError.failed(export.error?.localizedDescription ?? "unknown error")
        }
    }
}
