import XCTest
import CoreGraphics
@testable import SyncCore

final class PriorityFeatureTests: XCTestCase {
    func testTagCombinationsExclusionAndPersistence() throws {
        var filter = LibraryTagFilter(states: ["冒险": "yes", "Sci-Fi": "yes", "恋爱": "no"])
        XCTAssertTrue(filter.accepts(" 冒险，sci-fi\n冒险"))
        XCTAssertFalse(filter.accepts("冒险"))
        XCTAssertFalse(filter.accepts("冒险, Sci-Fi, 恋爱"))
        XCTAssertFalse(filter.accepts(nil))
        filter.matchAll = false
        XCTAssertTrue(filter.accepts("冒险"))
        XCTAssertTrue(filter.accepts("SCI-FI"))
        XCTAssertFalse(filter.accepts("冒险,恋爱"))
        XCTAssertEqual(try JSONDecoder().decode(LibraryTagFilter.self, from: JSONEncoder().encode(filter)), filter)
        filter.states = ["恋爱": "no"]
        XCTAssertTrue(filter.accepts(nil))
        XCTAssertTrue(filter.accepts("冒险"))
        XCTAssertFalse(filter.accepts("恋爱"))
        XCTAssertTrue(LibraryTagFilter().accepts(nil))
        XCTAssertEqual(MangaGenres.tags("冒险， 科幻\n冒险,,"), ["冒险", "科幻"])
    }

    func testPanClampsToEdgeBeforeTurningInBothDirections() {
        let size = CGSize(width: 100, height: 200), content = CGSize(width: 250, height: 500)
        XCTAssertEqual(PagePan.offset(current: .zero, content: content, viewport: size, direction: CGVector(dx: 1, dy: 0)), CGPoint(x: 90, y: 0))
        XCTAssertEqual(PagePan.offset(current: CGPoint(x: 90, y: 20), content: content, viewport: size, direction: CGVector(dx: 1, dy: 0)), CGPoint(x: 150, y: 20))
        XCTAssertNil(PagePan.offset(current: CGPoint(x: 150, y: 20), content: content, viewport: size, direction: CGVector(dx: 1, dy: 0)))
        XCTAssertEqual(PagePan.offset(current: CGPoint(x: 150, y: 20), content: content, viewport: size, direction: CGVector(dx: -1, dy: 0)), CGPoint(x: 60, y: 20))
        XCTAssertEqual(PagePan.offset(current: CGPoint(x: 20, y: 250), content: content, viewport: size, direction: CGVector(dx: 0, dy: 1)), CGPoint(x: 20, y: 300))
        XCTAssertNil(PagePan.offset(current: CGPoint(x: 20, y: 300), content: content, viewport: size, direction: CGVector(dx: 0, dy: 1)))
        XCTAssertNil(PagePan.offset(current: .zero, content: size, viewport: size, direction: CGVector(dx: -1, dy: 0)))
    }
}
