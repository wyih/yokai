import XCTest
@testable import SyncCore

final class ShelfMergeTests: XCTestCase {
    func testClearedHistoryKeepsProgressAndCanRecordNewReadingLater() {
        var old = book(); old.lastPage = 8; old.lastRead = Date(timeIntervalSince1970: 200)
        old.chapters = [ChapterProgress(url: "/chapter", title: "章节", pageCount: 20, lastPage: 8, completed: false, lastRead: old.lastRead)]
        var cleared = old; cleared.lastRead = nil; cleared.historyModifiedAt = Date(timeIntervalSince1970: 300)
        cleared.chapters?[0].lastRead = nil; cleared.chapters?[0].historyModifiedAt = cleared.historyModifiedAt
        let merged = ShelfMerge.merge(local: ShelfState(books: [cleared]), remote: ShelfState(books: [old]), baseline: [old.id: old.progressRevision]).state
        XCTAssertNil(merged.books[0].lastRead); XCTAssertNil(merged.books[0].chapters?[0].lastRead)
        XCTAssertEqual(merged.books[0].lastPage, 8); XCTAssertEqual(merged.books[0].chapters?[0].lastPage, 8)
        var readAgain = old; readAgain.lastRead = Date(timeIntervalSince1970: 400); readAgain.chapters?[0].lastRead = readAgain.lastRead
        let later = ShelfMerge.merge(local: merged, remote: ShelfState(books: [readAgain]), baseline: [old.id: old.progressRevision]).state
        XCTAssertEqual(later.books[0].lastRead, readAgain.lastRead); XCTAssertEqual(later.books[0].chapters?[0].lastRead, readAgain.lastRead)
    }
    private func book() -> ComicBook {
        ComicBook(id: String(repeating: "a", count: 64), title: "测试漫画", format: .images,
                  pageCount: 20, importedAt: Date(timeIntervalSince1970: 100))
    }

    func testConcurrentProgressRequiresChoiceButBookmarksMerge() {
        var local = book(), remote = local
        let baseline = [local.id: local.progressRevision]
        local.lastPage = 5; local.lastRead = Date(); local.progressRevision = "local"
        remote.lastPage = 11; remote.lastRead = Date(); remote.progressRevision = "remote"
        local.bookmarks = [ComicBookmark(page: 3, title: "本机书签")]
        remote.bookmarks = [ComicBookmark(page: 8, title: "远端书签")]
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]), baseline: baseline)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.state.books[0].bookmarks.count, 2)
        let chosen = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]),
                                     baseline: baseline, choices: [local.id: ProgressChoice(conflict: result.conflicts[0], keepLocal: false)])
        XCTAssertTrue(chosen.conflicts.isEmpty)
        XCTAssertEqual(chosen.state.books[0].lastPage, 11)
    }

    func testChoiceCannotOverwriteProgressChangedAfterConflictWasShown() {
        var local = book(), remote = local
        let baseline = [local.id: local.progressRevision]
        local.lastPage = 5; local.lastRead = Date(); local.progressRevision = "local"
        remote.lastPage = 11; remote.lastRead = Date(); remote.progressRevision = "remote"
        let conflict = ProgressConflict(local: local, remote: remote)
        let choices = [local.id: ProgressChoice(conflict: conflict, keepLocal: true)]
        remote.lastPage = 14; remote.progressRevision = "remote-after-choice"
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]),
                                      baseline: baseline, choices: choices)
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts[0].remote.lastPage, 14)
    }

    func testRemoteCanMoveProgressBackwards() {
        var local = book()
        local.lastPage = 15; local.lastRead = Date()
        let baseline = [local.id: local.progressRevision]
        var remote = local
        remote.lastPage = 2; remote.progressRevision = "restarted"
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]), baseline: baseline)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.state.books[0].lastPage, 2)
    }

    func testChapterBookmarkChangeSurvivesReadingProgressChoice() {
        var local = book(), remote = local
        local.origin = ComicOrigin(sourceID: "1", mangaURL: "/manga", chapterURL: "/chapter")
        remote.origin = local.origin
        local.lastPage = 7; local.progressRevision = "local"; local.lastRead = Date()
        remote.lastPage = 3; remote.progressRevision = "remote"; remote.lastRead = Date()
        local.chapters = [ChapterProgress(url: "/chapter", title: "第 1 章", pageCount: 20, lastPage: 7,
                                         completed: false, modifiedAt: Date(timeIntervalSince1970: 400))]
        remote.chapters = [ChapterProgress(url: "/chapter", title: "第 1 章", pageCount: 20, lastPage: 3,
                                          completed: false, modifiedAt: Date(timeIntervalSince1970: 200),
                                          bookmarked: true, bookmarkModifiedAt: Date(timeIntervalSince1970: 300))]
        let conflict = ProgressConflict(local: local, remote: remote)
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]),
                                      baseline: [:], choices: [local.id: ProgressChoice(conflict: conflict, keepLocal: true)])
        XCTAssertEqual(result.state.books[0].chapters?.first?.lastPage, 7)
        XCTAssertEqual(result.state.books[0].chapters?.first?.bookmarked, true)

        var unbookmarked = result.state.books[0]
        unbookmarked.chapters?[0].bookmarked = false
        unbookmarked.chapters?[0].bookmarkModifiedAt = Date(timeIntervalSince1970: 500)
        let cleared = ShelfMerge.merge(local: result.state, remote: ShelfState(books: [unbookmarked]),
                                       baseline: [local.id: "local"])
        XCTAssertEqual(cleared.state.books[0].chapters?.first?.bookmarked, false)
    }

    func testRemovingFromLibraryKeepsReadingHistoryWhenProgressMerges() {
        var local = book()
        let baseline = [local.id: local.progressRevision]
        var remote = local
        local.lastPage = 8; local.progressRevision = "read-on-device"; local.lastRead = Date(timeIntervalSince1970: 200)
        local.modifiedAt = Date(timeIntervalSince1970: 200)
        remote.inLibrary = false; remote.modifiedAt = Date(timeIntervalSince1970: 300)
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]), baseline: baseline)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.state.books.count, 1)
        XCTAssertEqual(result.state.books[0].inLibrary, false)
        XCTAssertEqual(result.state.books[0].lastPage, 8)
    }

    func testDeletionPropagatesAndLaterReimportRestoresBook() {
        var comic = book()
        comic.modifiedAt = Date(timeIntervalSince1970: 200)
        let deleted = ShelfState(deleted: [comic.id: Date(timeIntervalSince1970: 300)])
        let removed = ShelfMerge.merge(local: ShelfState(books: [comic]), remote: deleted, baseline: [:])
        XCTAssertTrue(removed.state.books.isEmpty)
        comic.modifiedAt = Date(timeIntervalSince1970: 400)
        let restored = ShelfMerge.merge(local: ShelfState(books: [comic]), remote: deleted, baseline: [:])
        XCTAssertEqual(restored.state.books.count, 1)
    }

    func testBookmarkDeletionDoesNotResurrect() {
        var comic = book()
        var mark = ComicBookmark(page: 1, title: "书签")
        mark.modifiedAt = Date(timeIntervalSince1970: 200)
        comic.bookmarks = [mark]
        var remote = comic
        remote.bookmarks[0].deleted = true
        remote.bookmarks[0].modifiedAt = Date(timeIntervalSince1970: 300)
        let result = ShelfMerge.merge(local: ShelfState(books: [comic]), remote: ShelfState(books: [remote]), baseline: [:])
        XCTAssertTrue(result.state.books[0].bookmarks[0].deleted)
    }

    func testRejectsPathTraversalAndDuplicateRemoteIDs() {
        var comic = book()
        comic = ComicBook(id: "../bad", title: comic.title, format: comic.format, pageCount: 1, importedAt: Date())
        XCTAssertThrowsError(try ShelfMerge.validate(ShelfState(books: [comic])))
        let valid = book()
        XCTAssertThrowsError(try ShelfMerge.validate(ShelfState(books: [valid, valid])))
    }
}

extension ShelfMergeTests {
    func testCategoryRenameAndDeletionDoNotResurrectOlderRecords() throws {
        let original = ShelfCategory(id: "category", name: "收藏", order: 0, modifiedAt: Date(timeIntervalSince1970: 100))
        var renamed = original; renamed.name = "正在阅读"; renamed.modifiedAt = Date(timeIntervalSince1970: 200)
        var removed = renamed; removed.deleted = true; removed.modifiedAt = Date(timeIntervalSince1970: 300)
        let rename = ShelfMerge.merge(local: ShelfState(categories: [original]), remote: ShelfState(categories: [renamed]), baseline: [:])
        XCTAssertEqual(rename.state.categories?.first?.name, "正在阅读")
        let delete = ShelfMerge.merge(local: ShelfState(categories: [removed]), remote: ShelfState(categories: [original]), baseline: [:])
        XCTAssertEqual(delete.state.categories?.count, 1)
        XCTAssertEqual(delete.state.categories?.first?.deleted, true)
        try ShelfMerge.validate(delete.state)
    }

    func testReadingModeSurvivesIndependentProgressMerge() throws {
        var local = book(), remote = local
        let baseline = [local.id: local.progressRevision]
        local.readerSettings = MangaReaderSettings(mode: "rtl", trimBorders: true)
        local.modifiedAt = Date(timeIntervalSince1970: 300)
        remote.lastRead = Date(timeIntervalSince1970: 200); remote.lastPage = 7; remote.progressRevision = "remote-progress"
        remote.modifiedAt = Date(timeIntervalSince1970: 200)
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]), baseline: baseline)
        XCTAssertEqual(result.state.books[0].readerSettings?.mode, "rtl")
        XCTAssertEqual(result.state.books[0].readerSettings?.trimBorders, true)
        XCTAssertEqual(result.state.books[0].lastPage, 7)
        try ShelfMerge.validate(result.state)
    }

    func testDifferentChaptersWithSamePageRequireConflictChoice() throws {
        var local = ComicBook(id: String(repeating: "b", count: 64), title: "在线漫画", format: .images, pageCount: 12, importedAt: Date())
        local.origin = ComicOrigin(sourceID: "source", mangaURL: "/comic", chapterURL: "/chapter/1", chapterTitle: "第一章")
        var remote = local
        let baseline = [local.id: local.progressRevision]
        local.lastPage = 4; local.lastRead = Date(); local.progressRevision = "local"
        remote.origin?.chapterURL = "/chapter/2"; remote.origin?.chapterTitle = "第二章"
        remote.pageCount = 30; remote.lastPage = 4; remote.lastRead = Date(); remote.progressRevision = "remote"
        local.bookmarks = [ComicBookmark(page: 11, title: "第一章书签", chapterURL: "/chapter/1", pageCount: 12)]
        let conflict = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]), baseline: baseline)
        XCTAssertEqual(conflict.conflicts.count, 1)
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]), baseline: baseline, choices: [local.id: ProgressChoice(conflict: conflict.conflicts[0], keepLocal: false)])
        XCTAssertEqual(result.state.books[0].origin?.chapterURL, "/chapter/2")
        XCTAssertEqual(result.state.books[0].pageCount, 30)
        XCTAssertEqual(result.state.books[0].bookmarks[0].chapterURL, "/chapter/1")
        try ShelfMerge.validate(result.state)
    }
}

extension ShelfMergeTests {
    func testChosenCurrentChapterProgressOverridesNewerUnchosenHistory() {
        var local = book(), remote = local
        local.origin = ComicOrigin(sourceID: "source", mangaURL: "/comic", chapterURL: "/chapter/1", chapterTitle: "第一章")
        remote.origin = local.origin
        local.lastPage = 2; local.lastRead = Date(); local.progressRevision = "local"
        remote.lastPage = 10; remote.lastRead = Date(); remote.progressRevision = "remote"
        local.chapters = [ChapterProgress(url: "/chapter/1", title: "第一章", pageCount: 20, lastPage: 2, completed: false, modifiedAt: Date(timeIntervalSince1970: 100))]
        remote.chapters = [ChapterProgress(url: "/chapter/1", title: "第一章", pageCount: 20, lastPage: 10, completed: false, modifiedAt: Date(timeIntervalSince1970: 200))]
        let conflict = ProgressConflict(local: local, remote: remote)
        let result = ShelfMerge.merge(local: ShelfState(books: [local]), remote: ShelfState(books: [remote]), baseline: [:], choices: [local.id: ProgressChoice(conflict: conflict, keepLocal: true)])
        XCTAssertEqual(result.state.books[0].lastPage, 2)
        XCTAssertEqual(result.state.books[0].chapters?[0].lastPage, 2)
    }
}
