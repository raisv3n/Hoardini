import XCTest
@testable import HoardiniCore

final class SegmentsTests: XCTestCase {
    func testPlanCoversRangeExactlyWithoutGaps() {
        for length in [1, 100, 262_144, 1_000_001, 50_000_000] as [Int64] {
            for count in [1, 3, 8, 32] {
                let segs = SegmentPlanner.plan(length: length, count: count)
                XCTAssertEqual(segs.first?.start, 0)
                XCTAssertEqual(segs.last?.end, length - 1)
                for (a, b) in zip(segs, segs.dropFirst()) { XCTAssertEqual(a.end + 1, b.start) }
                XCTAssertLessThanOrEqual(segs.count, count)
            }
        }
    }

    func testSmallFileGetsOneSegment() {
        XCTAssertEqual(SegmentPlanner.plan(length: 1000, count: 8).count, 1)
    }

    func testContentDisposition() {
        XCTAssertEqual(Probe.parseContentDisposition("attachment; filename=\"a b.zip\""), "a b.zip")
        XCTAssertEqual(Probe.parseContentDisposition("attachment; filename=\"x.txt\"; filename*=UTF-8''%E2%82%AC.txt"), "€.txt")
    }

    func testSanitizeBlocksTraversal() {
        XCTAssertEqual(Probe.sanitize("../../etc/passwd"), "_.._etc_passwd")
        XCTAssertEqual(Probe.sanitize("..."), "download")
    }
}
