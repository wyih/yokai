#!/usr/bin/env python3
"""Run real migration methods against controlled storage failures and shelf fixtures.

Requires the installed Swift compiler. Each run extracts the current production
methods; only persistence and cache boundaries are substituted. No Xcode build.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
build = root / "ios/build/migration-check"
build.mkdir(parents=True, exist_ok=True)
lib=(root/'ios/Yokai/ComicLibrary.swift').read_text()
source=(root/'ios/Yokai/SourceEngine.swift').read_text()
view=(root/'ios/Yokai/SourceMigrationView.swift').read_text()
models=(root/'ios/Yokai/SyncCore/Models.swift').read_text()
def function(text, start, end): return text[text.index(start):text.index(end,text.index(start))]
shared=source[source.index('struct MangaSource:'):source.index('struct InstalledExtension:')]
apply=function(lib,'    func applyMigration(', '\n    func clearHistory(')
hash_method=function(lib,'    nonisolated static func hash(', '\n    func addOnline(')
add=function(lib,'    func addOnline(', '\n    func setFavorite(')
favorite=function(lib,'    func setFavorite(', '\n    func cachedDetails(')
helper=view[view.index('enum SourceMigration {'):]
header='''import Foundation
import CryptoKit
enum SourceError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
struct TestDefaults { func string(forKey: String) -> String? { nil } }
enum YokaiStorage { static let defaults = TestDefaults() }
'''
stub='''
@MainActor final class ComicLibrary {
    var books: [ComicBook] = []
    var errorMessage: String?
    var deleted: [String: Date] = [:]
    var details: [String: SourceDetails] = [:]
    var failCache = false
    var failFlush: Int?
    var flushes = 0
    func save() {}
    func cachedDetails(for book: ComicBook) -> SourceDetails? { details[book.id] }
    func cacheImportedDetails(_ value: SourceDetails, bookID: String) throws {
        if failCache { throw SourceError.message("injected cache failure") }; details[bookID] = value
    }
    func saveDetails(_ value: SourceDetails, source: MangaSource) { details[Self.hash(source.id + "\\n" + value.manga.url)] = value }
    func flushPendingSaves() async throws { flushes += 1; if flushes == failFlush { throw SourceError.message("injected disk failure") } }
'''+hash_method+add+favorite+apply+'}\n'
tests=r'''
@main struct Check {
    @MainActor static func main() async throws {
        let source = MangaSource(sourceID: "new-source", name: "Target", lang: "zh", latest: nil, baseURL: nil, package: "new", error: nil)
        let now = Date(timeIntervalSince1970: 123456)
        func chapter(_ url: String, _ name: String, _ number: Double) -> SourceChapter { SourceChapter(url: url, name: name, number: number, uploaded: 0) }
        let oldChapter = chapter("old-1", "第1话", 1)
        let newChapter = chapter("new-1", "Chapter 1", 1)
        var original = ComicBook(id: "original", title: "原书", format: .images, pageCount: 20, lastPage: 9, lastRead: now, importedAt: now)
        original.origin = ComicOrigin(sourceID: "old-source", mangaURL: "old", chapterURL: "old-1", chapterTitle: "第1话")
        original.inLibrary = true
        original.categories = ["分类甲"]
        original.readerSettings = MangaReaderSettings(mode: "webtoon")
        original.chapters = [ChapterProgress(url: "old-1", title: "第1话", pageCount: 20, lastPage: 9, completed: false, lastRead: now, bookmarked: true)]
        original.bookmarks = [ComicBookmark(page: 7, title: "书签", modifiedAt: now, chapterURL: "old-1", pageCount: 20)]
        let details = SourceDetails(manga: SourceManga(url: "new", title: "新书"), chapters: [newChapter])
        let oldDetails = SourceDetails(manga: SourceManga(url: "old", title: "原书"), chapters: [oldChapter])
        let matches = SourceMigration.matches(original: original, previous: [oldChapter], destination: [newChapter])
        assert(matches == ["old-1":"new-1"])
        assert(SourceMigration.canRemoveOriginal(original, matches: matches))
        let ambiguous = [newChapter, chapter("new-1b", "另一汉化组", 1)]
        assert(SourceMigration.matches(original: original, previous: [oldChapter], destination: ambiguous).isEmpty)
        assert(SourceMigration.matches(original: original, previous: [oldChapter], destination: [newChapter, chapter("new-1b", "第1话", 1)]) == ["old-1":"new-1b"])
        var duplicate = original
        duplicate.chapters?.append(ChapterProgress(url: "old-1b", title: "别版", pageCount: 20, lastPage: 0, completed: false))
        assert(SourceMigration.matches(original: duplicate, previous: [oldChapter, chapter("old-1b", "别版", 1)], destination: [newChapter]).isEmpty)
        var bookmarkOnly = original; bookmarkOnly.chapters = []
        assert(SourceMigration.matches(original: bookmarkOnly, previous: [oldChapter], destination: [newChapter]) == matches)
        var looseBookmark = original; looseBookmark.bookmarks.append(ComicBookmark(page: 0, title: "旧格式书签"))
        assert(!SourceMigration.canRemoveOriginal(looseBookmark, matches: matches))
        func library() -> ComicLibrary {
            let lib = ComicLibrary(); lib.books = [original]; lib.details[original.id] = oldDetails; return lib
        }
        let lib = library()
        let result = try await SourceMigration.apply(original: original, source: source, details: details, library: lib, removeOriginal: true)
        assert(result.inLibrary == true && result.lastPage == 9 && result.lastRead == now)
        assert(result.origin?.chapterURL == "new-1" && result.categories == ["分类甲"])
        assert(result.chapters?.first?.bookmarked == true && result.chapters?.first?.lastRead == now)
        assert(result.bookmarks.count == 1 && result.bookmarks.first?.chapterURL == "new-1" && result.bookmarks.first?.page == 7)
        assert(result.readerSettings?.mode == "webtoon")
        assert(lib.books.first { $0.id == original.id }?.inLibrary == false && lib.flushes == 3)
        let cacheFailure = library(); cacheFailure.failCache = true
        do { _ = try await SourceMigration.apply(original: original, source: source, details: details, library: cacheFailure, removeOriginal: true); assertionFailure() } catch {}
        assert(cacheFailure.books == [original])
        let writeFailure = library(); writeFailure.failFlush = 2
        do { _ = try await SourceMigration.apply(original: original, source: source, details: details, library: writeFailure, removeOriginal: true); assertionFailure() } catch {}
        assert(writeFailure.books.first { $0.id == original.id }?.inLibrary == true)
        writeFailure.failFlush = nil
        let retried = try await SourceMigration.apply(original: original, source: source, details: details, library: writeFailure, removeOriginal: true)
        assert(retried.bookmarks.count == 1 && writeFailure.books.count == 2)
        let unmatched = library()
        let noMatch = SourceDetails(manga: details.manga, chapters: [chapter("other", "外传", 8)])
        _ = try await SourceMigration.apply(original: original, source: source, details: noMatch, library: unmatched, removeOriginal: true)
        assert(unmatched.books.first { $0.id == original.id } == original)
        let missing = library(); missing.books = []
        do { _ = try await SourceMigration.apply(original: original, source: source, details: details, library: missing, removeOriginal: true); assertionFailure() } catch {}
        assert(missing.books.isEmpty)
        let completedTarget = library()
        let targetID = ComicLibrary.hash(source.id + "\n" + details.manga.url)
        let earlier = now.addingTimeInterval(-600)
        let later = now.addingTimeInterval(600)
        var existing = ComicBook(id: targetID, title: "已读目标", format: .images,
            pageCount: 24, lastPage: 23, lastRead: earlier, importedAt: earlier)
        existing.inLibrary = true
        existing.origin = ComicOrigin(sourceID: source.id, mangaURL: details.manga.url,
            chapterURL: "new-1", chapterTitle: "Chapter 1")
        existing.chapters = [ChapterProgress(url: "new-1", title: "Chapter 1", pageCount: 24,
            lastPage: 23, completed: true, lastRead: earlier, bookmarked: false)]
        completedTarget.books.append(existing)
        let merged = try await SourceMigration.apply(original: original, source: source, details: details,
            library: completedTarget, removeOriginal: true)
        let completed = merged.chapters!.first { $0.url == "new-1" }!
        assert(completed.completed && completed.lastPage == 23 && completed.pageCount == 24,
            "Previously completed target must keep its finished position")
        assert(completed.bookmarked == true && completed.lastRead == now,
            "Source bookmark and newer history must merge into completed target")
        assert(completed.bookmarkModifiedAt != nil && completed.historyModifiedAt != nil)
        assert(merged.lastRead == now && merged.lastPage == 23 && merged.pageCount == 24)
        assert(merged.bookmarks.count == 1 && merged.bookmarks[0].chapterURL == "new-1")
        assert(completedTarget.books.first { $0.id == original.id }?.inLibrary == false)
        print("PASS: completed target keeps completion and position; source bookmark and newer history merge")

        let newerTarget = library()
        existing.lastRead = later; existing.lastPage = 17; existing.pageCount = 30
        existing.categories = ["分类乙"]
        existing.chapters = [ChapterProgress(url: "new-1", title: "Chapter 1", pageCount: 30,
            lastPage: 17, completed: false, lastRead: later, bookmarked: false)]
        let existingRevision = existing.progressRevision
        newerTarget.books.append(existing)
        let newer = try await SourceMigration.apply(original: original, source: source, details: details,
            library: newerTarget, removeOriginal: false)
        let newerChapter = newer.chapters!.first { $0.url == "new-1" }!
        assert(newerChapter.lastPage == 17 && newerChapter.pageCount == 30 && !newerChapter.completed)
        assert(newerChapter.lastRead == later && newerChapter.bookmarked == true)
        assert(newer.origin?.chapterURL == "new-1" && newer.lastPage == 17 && newer.pageCount == 30)
        assert(newer.lastRead == later && newer.progressRevision == existingRevision,
            "Newer target resume position and revision must not be reset by migration")
        assert(Set(newer.categories ?? []) == ["分类甲", "分类乙"])
        print("PASS: newer target preserves same-chapter progress, resume position and revision")

        let otherChapterTarget = library()
        let second = chapter("new-2", "Chapter 2", 2)
        existing.origin?.chapterURL = second.url; existing.origin?.chapterTitle = second.name
        existing.origin?.chapterMemo = "keep-current-memo"
        existing.lastPage = 8; existing.pageCount = 40
        existing.chapters?.append(ChapterProgress(url: second.url, title: second.name, pageCount: 40,
            lastPage: 8, completed: false, lastRead: later))
        existing.readerSettings = MangaReaderSettings(mode: "pager")
        var sourceWithoutSettings = original; sourceWithoutSettings.readerSettings = nil
        otherChapterTarget.books = [sourceWithoutSettings, existing]
        let twoChapters = SourceDetails(manga: details.manga, chapters: [newChapter, second])
        let other = try await SourceMigration.apply(original: sourceWithoutSettings, source: source,
            details: twoChapters, library: otherChapterTarget, removeOriginal: false)
        assert(other.origin == existing.origin && other.lastPage == 8 && other.pageCount == 40,
            "Newer target reading another chapter must keep its complete resume location")
        assert(other.lastRead == later && other.progressRevision == existingRevision)
        assert(other.chapters?.first { $0.url == second.url } == existing.chapters?.first { $0.url == second.url })
        assert(other.readerSettings?.mode == "pager", "Missing source settings must not erase target settings")
        let repeated = try await SourceMigration.apply(original: sourceWithoutSettings, source: source,
            details: twoChapters, library: otherChapterTarget, removeOriginal: false)
        assert(repeated.bookmarks.count == other.bookmarks.count && repeated.lastPage == 8)
        print("PASS: newer target keeps different-chapter resume; retry adds no duplicate bookmarks")
        print("PASS: unique/ambiguous matching, marker-only chapter, full migration, cache/write failure, retry and unmatched/missing originals")
    }
}
'''
out = build / "MigrationCheck.swift"
out.write_text(header + models + shared + stub + helper + tests)
binary = build / "MigrationCheck"
subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(out), "-o", str(binary)], check=True)
subprocess.run([str(binary)], check=True)
