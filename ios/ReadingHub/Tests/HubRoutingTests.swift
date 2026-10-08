import XCTest
@testable import HubRouting

final class HubRoutingTests: XCTestCase {
    func testDirectLaunchRoutesAndRemoteURLs() {
        XCTAssertEqual(HubRoute.module(for: URL(string: "readinghub://qiye")!), .qiye)
        XCTAssertEqual(HubRoute.module(for: URL(string: "readinghub://yokai")!), .yokai)
        XCTAssertNil(HubRoute.module(for: URL(string: "readinghub://missing")!))
        XCTAssertNil(HubRoute.module(for: URL(string: "https://qiye")!))
        XCTAssertNil(HubRoute.fileModule(for: URL(string: "https://example.com/secret.apk")!))
    }
    func testExternalImportsReachTheOriginalReader() {
        for ext in ["epub", "txt", "mobi", "azw3", "html", "ttf"] {
            XCTAssertEqual(HubRoute.fileModule(for: URL(fileURLWithPath: "/incoming/book." + ext)), .qiye)
        }
        for ext in ["apk", "jar", "tachibk", "tmb", "jpg", "zip", "json"] {
            XCTAssertEqual(HubRoute.fileModule(for: URL(fileURLWithPath: "/incoming/book." + ext)), .yokai)
        }
        for ext in ["PDF", "cbz"] {
            XCTAssertNil(HubRoute.fileModule(for: URL(fileURLWithPath: "/incoming/book." + ext)))
        }
    }
}
