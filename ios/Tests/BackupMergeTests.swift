import XCTest
@testable import SyncCore

final class BackupMergeTests: XCTestCase {
    private func book() -> ComicBook {
        var book = ComicBook(id: String(repeating: "c", count: 64), title: "漫画", format: .images, pageCount: 20, importedAt: Date())
        book.origin = ComicOrigin(sourceID: "-123", mangaURL: "/manga", chapterURL: "/1")
        book.lastRead = Date(timeIntervalSince1970: 200); book.lastPage = 8
        return book
    }
    func testBackupProgressRestoresWhileCompletedChaptersAndBookmarksSurvive() throws {
        var current = book(), backup = current
        current.chapters = [
            ChapterProgress(url: "/1", title: "第一章", pageCount: 20, lastPage: 8, completed: false, lastRead: current.lastRead),
            ChapterProgress(url: "/2", title: "第二章", pageCount: 10, lastPage: 9, completed: true, bookmarked: true),
            ChapterProgress(url: "/3", title: "第三章", pageCount: 30, lastPage: 17, completed: false),
        ]
        backup.lastRead = Date(timeIntervalSince1970: 300); backup.lastPage = 4; backup.progressRevision = "backup"
        backup.chapters = [
            ChapterProgress(url: "/1", title: "旧标题", pageCount: 20, lastPage: 4, completed: false, lastRead: backup.lastRead),
            ChapterProgress(url: "/2", title: "第二章", pageCount: 1, lastPage: 0, completed: false, bookmarked: false),
            ChapterProgress(url: "/3", title: "第三章", pageCount: 1, lastPage: 0, completed: false),
        ]
        let result = AndroidBackupMerge.restore(current: ShelfState(books: [current]), backup: ShelfState(books: [backup]))
        try ShelfMerge.validate(result)
        let restored = result.books[0]
        XCTAssertEqual(restored.lastPage, 4); XCTAssertEqual(restored.lastRead, backup.lastRead)
        let chapters = Dictionary(uniqueKeysWithValues: restored.chapters!.map { ($0.url, $0) })
        XCTAssertEqual(chapters["/1"]?.title, "第一章")
        XCTAssertEqual(chapters["/2"]?.lastPage, 9); XCTAssertEqual(chapters["/2"]?.completed, true)
        XCTAssertEqual(chapters["/2"]?.bookmarked, true)
        XCTAssertEqual(chapters["/3"]?.lastPage, 17); XCTAssertEqual(chapters["/3"]?.pageCount, 30)
    }
    func testRestoreKeepsLaterHistoryAndMatchesCategoriesByName() throws {
        var current = book(), backup = current
        current.categories = ["正在读"]
        current.chapters = [ChapterProgress(url: "/1", title: "第一章", pageCount: 20, lastPage: 8, completed: false, lastRead: current.lastRead)]
        backup.lastRead = Date(timeIntervalSince1970: 100); backup.origin?.chapterURL = "/2"
        backup.chapters = [ChapterProgress(url: "/2", title: "第二章", pageCount: 12, lastPage: 6, completed: false, lastRead: backup.lastRead)]
        backup.categories = []
        let category = ShelfCategory(id: "local", name: "正在读", order: 1)
        let result = AndroidBackupMerge.restore(current: ShelfState(books: [current], categories: [category]),
            backup: ShelfState(books: [backup], categories: [ShelfCategory(id: "android", name: "正在读", order: 0)]))
        try ShelfMerge.validate(result)
        XCTAssertEqual(result.books[0].origin?.chapterURL, "/1"); XCTAssertEqual(result.books[0].lastPage, 8)
        XCTAssertEqual(result.books[0].lastRead, current.lastRead); XCTAssertEqual(result.books[0].chapters?.count, 2)
        XCTAssertEqual(result.books[0].categories, ["正在读"])
        XCTAssertEqual(result.categories, [category])
    }
    func testRestoringHistoryAfterClearingItSurvivesNextSync() {
        var cleared = book(), backup = cleared
        cleared.lastRead = nil; cleared.historyModifiedAt = Date(timeIntervalSince1970: 300)
        cleared.chapters = [ChapterProgress(url: "/1", title: "第一章", pageCount: 20, lastPage: 8, completed: false,
            historyModifiedAt: cleared.historyModifiedAt)]
        backup.lastRead = Date(timeIntervalSince1970: 100)
        backup.chapters = [ChapterProgress(url: "/1", title: "第一章", pageCount: 20, lastPage: 8, completed: false, lastRead: backup.lastRead)]
        let restored = AndroidBackupMerge.restore(current: ShelfState(books: [cleared]), backup: ShelfState(books: [backup]))
        let synced = ShelfMerge.merge(local: restored, remote: ShelfState(books: [cleared]), baseline: [:]).state
        XCTAssertEqual(synced.books[0].lastRead, backup.lastRead)
        XCTAssertEqual(synced.books[0].chapters?.first?.lastRead, backup.lastRead)
    }
}
