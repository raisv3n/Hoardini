import CoreServices
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

    func testSanitizeStripsInvisibleCharacters() {
        XCTAssertEqual(Probe.sanitize("photo\u{202E}gpj.command"), "photogpj.command")
        XCTAssertEqual(Probe.sanitize("a%0Ab.txt"), "ab.txt")
    }

    func testQuarantineMarksFile() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        Quarantine.mark(f, source: URL(string: "https://example.com/x")!, referrer: "https://example.com/")
        let props = try f.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertEqual(props?[kLSQuarantineAgentNameKey as String] as? String, "Hoardini")
    }

    func testMasterWithSeparateAudio() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud-lo",NAME="low",DEFAULT=NO,URI="audio/lo.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud-hi",NAME="high",DEFAULT=YES,URI="audio/hi.m3u8"
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=900,BANDWIDTH=1000,AUDIO="aud-lo"
        v/360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000,AUDIO="aud-hi"
        v/1080.m3u8
        """
        let base = URL(string: "https://cdn.example/x/master.m3u8")!
        guard case .master(let variants, let audio) = HLS.parse(text, base: base) else { return XCTFail("not a master") }
        XCTAssertEqual(variants.map(\.bandwidth), [1000, 5000])
        XCTAssertEqual(audio.count, 2)

        let best = HLS.pick(variants, preferred: nil)!
        XCTAssertEqual(best.url.absoluteString, "https://cdn.example/x/v/1080.m3u8")
        XCTAssertEqual(HLS.audioURL(for: best, in: audio)?.absoluteString, "https://cdn.example/x/audio/hi.m3u8")

        let low = HLS.pick(variants, preferred: URL(string: "https://cdn.example/x/v/360.m3u8"))!
        XCTAssertEqual(HLS.audioURL(for: low, in: audio)?.absoluteString, "https://cdn.example/x/audio/lo.m3u8")
    }

    func testMasterWithMuxedAudioNeedsNoSeparateTrack() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="main",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"
        v.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000
        w.m3u8
        """
        guard case .master(let variants, let audio) = HLS.parse(text, base: URL(string: "https://e.x/m.m3u8")!) else {
            return XCTFail("not a master")
        }
        for v in variants { XCTAssertNil(HLS.audioURL(for: v, in: audio)) }
    }
}
