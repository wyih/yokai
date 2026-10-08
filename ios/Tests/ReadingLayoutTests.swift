import XCTest
@testable import SyncCore

final class ReadingLayoutTests: XCTestCase {
    func testDoubleLayoutKeepsWidePagesAloneAndCanShowCoverAlone() {
        let frames = ReadingLayout.frames(count: 6, wide: [3], double: true, split: false, rightFirst: false, shift: false)
        XCTAssertEqual(frames.map { $0.segments.map(\.page) }, [[0, 1], [2], [3], [4, 5]])
        let shifted = ReadingLayout.frames(count: 6, wide: [], double: true, split: false, rightFirst: true, shift: true)
        XCTAssertEqual(shifted.map { $0.segments.map(\.page) }, [[0], [1, 2], [3, 4], [5]])
    }
    func testSplitUsesSourcePageIdentityAndReadingDirection() {
        let frames = ReadingLayout.frames(count: 3, wide: [1, 2], double: false, split: true, rightFirst: true, shift: false)
        XCTAssertEqual(frames.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(frames.flatMap(\.segments), [ReadingSegment(page: 0), ReadingSegment(page: 1, half: 1),
            ReadingSegment(page: 1, half: 0), ReadingSegment(page: 2, half: 1), ReadingSegment(page: 2, half: 0)])
        XCTAssertEqual(frames.last?.segments.first?.page, 2)
        let ltr = ReadingLayout.frames(count: 1, wide: [0], double: false, split: true, rightFirst: false, shift: false)
        XCTAssertEqual(ltr.flatMap(\.segments).map(\.half), [0, 1])
    }
}
