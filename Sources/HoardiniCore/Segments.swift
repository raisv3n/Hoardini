import Foundation

/// A contiguous inclusive byte range of the target file and how much of it is on disk.
public struct Segment: Codable, Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var written: Int64

    public init(start: Int64, end: Int64, written: Int64 = 0) {
        self.start = start
        self.end = end
        self.written = written
    }

    public var nextOffset: Int64 { start + written }
    public var isDone: Bool { nextOffset > end }
}

public enum SegmentPlanner {
    /// Splits `length` bytes into at most `count` segments, none smaller than `minSize`
    /// (except when the whole file is smaller than that).
    public static func plan(length: Int64, count: Int, minSize: Int64 = 256 * 1024) -> [Segment] {
        guard length > 0 else { return [] }
        let byMinSize = max(1, Int(length / max(1, minSize)))
        let n = max(1, min(count, byMinSize))
        let chunk = (length + Int64(n) - 1) / Int64(n)
        var segments: [Segment] = []
        var start: Int64 = 0
        while start < length {
            let end = min(start + chunk - 1, length - 1)
            segments.append(Segment(start: start, end: end))
            start = end + 1
        }
        return segments
    }
}
