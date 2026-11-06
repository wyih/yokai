import XCTest
@testable import SyncCore

final class ReadingFeatureTests: XCTestCase {
    private let chapters: [(url: String, title: String, number: Double)] = [
        ("a", "甲组第1话", 1), ("b", "乙组第1话", 1), ("new", "新增第1话", 1),
        ("next", "第2话", 2), ("special", "番外", -1), ("other", "另一个番外", -1)
    ]

    func testDuplicateMarkingPreservesBookmarksAndHistory() {
        let date = Date(timeIntervalSince1970: 100)
        let original = ChapterProgress(url: "b", title: "乙组第1话", pageCount: 12, lastPage: 3, completed: false,
            modifiedAt: date, lastRead: date, bookmarked: true, bookmarkModifiedAt: date, historyModifiedAt: date)
        let marked = DuplicateChapterProgress.marking([original], chapters: chapters, completedURLs: ["a"])
        let duplicate = marked.first { $0.url == "b" }!
        XCTAssertTrue(duplicate.completed)
        XCTAssertEqual(duplicate.lastPage, 3)
        XCTAssertEqual(duplicate.lastRead, date)
        XCTAssertEqual(duplicate.bookmarked, true)
        XCTAssertEqual(duplicate.bookmarkModifiedAt, date)
        XCTAssertEqual(duplicate.historyModifiedAt, date)
        XCTAssertEqual(Set(marked.map(\.url)), ["b", "new"])
        XCTAssertNil(marked.first { $0.url == "new" }?.lastRead)
        XCTAssertEqual(DuplicateChapterProgress.marking(marked, chapters: chapters, completedURLs: ["a"]), marked)
    }

    func testNewDuplicateScopeDoesNotChangeExistingUnreadChapters() {
        let result = DuplicateChapterProgress.marking([], chapters: chapters, completedURLs: ["a"], eligibleURLs: ["new", "next"])
        XCTAssertEqual(result.map(\.url), ["new"])
        XCTAssertTrue(result[0].completed)
        XCTAssertTrue(DuplicateChapterProgress.marking([], chapters: chapters, completedURLs: ["special"]).isEmpty)
        XCTAssertTrue(DuplicateChapterProgress.marking([], chapters: chapters, completedURLs: []).isEmpty)
    }

    func testMarkdownKeepsParagraphsListsEmphasisAndLinks() {
        let rendered = MangaDescription.render("首行 **加粗**\n次行\n\n- 项一\n- [网站](https://example.org)\n\n1. 第一\n2. 第二\n\n### 标题")
        XCTAssertEqual(String(rendered.characters), "首行 加粗\n次行\n\n• 项一\n\n• 网站\n\n1. 第一\n\n2. 第二\n\n标题")
        XCTAssertTrue(rendered.runs.contains { String(rendered[$0.range].characters) == "加粗" && $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(rendered.runs.contains { $0.link == URL(string: "https://example.org") })
        XCTAssertEqual(String(MangaDescription.render("普通简介\n保留换行。\n\n第二段。").characters), "普通简介\n保留换行。\n\n第二段。")
    }
}
