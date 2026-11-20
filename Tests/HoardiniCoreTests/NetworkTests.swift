import XCTest
@testable import HoardiniCore

final class NetworkTests: XCTestCase {
    private let creds = ["Cookie": "a=b", "Authorization": "Bearer x", "Referer": "https://site.com/"]
    private func u(_ s: String) -> URL { URL(string: s)! }

    func testSameHostKeepsCredentials() {
        XCTAssertEqual(Net.headers(creds, for: u("https://cdn.site.com/seg.ts"), origin: u("https://CDN.site.com/master.m3u8")), creds)
    }

    func testOtherHostDropsCredentials() {
        let h = Net.headers(creds, for: u("https://evil.example/seg.ts"), origin: u("https://site.com/master.m3u8"))
        XCTAssertEqual(h, ["Referer": "https://site.com/"])
    }

    func testHTTPSDowngradeDropsCredentials() {
        let h = Net.headers(creds, for: u("http://site.com/seg.ts"), origin: u("https://site.com/master.m3u8"))
        XCTAssertEqual(h, ["Referer": "https://site.com/"])
    }

    func testHTTPUpgradeAndOtherPortKeepCredentials() {
        XCTAssertTrue(Net.mayCarryCredentials(to: u("https://site.com/a"), from: u("http://site.com/b")))
        XCTAssertTrue(Net.mayCarryCredentials(to: u("https://site.com:8443/a"), from: u("https://site.com/b")))
    }
}
