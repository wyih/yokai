// Run with swiftc alongside SyncCore/Models.swift and ComicStorage.swift.
import Foundation
import CryptoKit

@main
struct StorageManagementChecks {
    static func main() async throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent("yokai-storage-check-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Comics"), covers = sandbox.appendingPathComponent("SourceCovers")
        let backups = sandbox.appendingPathComponent("Backups"), external = sandbox.appendingPathComponent("UserBackups")
        let temporary = sandbox.appendingPathComponent("SharedTemporary")
        func write(_ url: URL, _ count: Int) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: count).write(to: url)
        }
        let localID = hash("local"), onlineID = hash("source\nmanga"), chapterURL = "/chapter/one"
        let local = ComicBook(id: localID, title: "本地原件", format: .pdf, pageCount: 2, importedAt: Date())
        var online = ComicBook(id: onlineID, title: "在线漫画", format: .images, pageCount: 2, importedAt: Date())
        online.origin = ComicOrigin(sourceID: "source", mangaURL: "manga")
        online.inLibrary = true
        let onlineFolder = root.appendingPathComponent(onlineID)
        let chapter = onlineFolder.appendingPathComponent("chapters/" + hash(chapterURL))
        try write(chapter.appendingPathComponent("000000"), 100)
        try write(chapter.appendingPathComponent("000001"), 200)
        let marker = Data("{\"chapter\":{\"url\":\"/chapter/one\"},\"pageCount\":2}".utf8)
        try marker.write(to: chapter.appendingPathComponent("chapter.json"))
        let partial = onlineFolder.appendingPathComponent("chapters/" + hash("/partial"))
        try write(partial.appendingPathComponent("000000.part"), 75)
        try write(onlineFolder.appendingPathComponent("manga.json"), 50)
        try write(onlineFolder.appendingPathComponent("cover.jpg"), 30)
        try write(root.appendingPathComponent(localID + "/comic.pdf"), 500)
        try write(root.appendingPathComponent("library.json"), 60)
        let completedCover = covers.appendingPathComponent(hash("source\ncover"))
        let stagingCover = covers.appendingPathComponent(UUID().uuidString)
        try write(completedCover, 80)
        try write(stagingCover, 40)
        let oldest = backups.appendingPathComponent("yokai_2026-10-01_01-00.tachibk")
        let latest = backups.appendingPathComponent("yokai_2026-10-02_01-00.tachibk")
        try write(oldest, 20); try write(latest, 30)
        try write(backups.appendingPathComponent("unrelated.txt"), 90)
        try write(external.appendingPathComponent("yokai_2026-10-03_01-00.tachibk"), 45)
        try write(temporary.appendingPathComponent("active-import.pdf"), 70)
        let outside = sandbox.appendingPathComponent("private-data")
        try write(outside, 90)
        try manager.createSymbolicLink(at: covers.appendingPathComponent(hash("linked-cover")), withDestinationURL: outside)

        let inputBooks = [local, online]
        let inventory = try await Task.detached {
            try requireBackgroundThread()
            return try ComicStorage.scan(books: inputBooks, root: root, covers: covers, backups: backups,
                                         externalBackups: external, temporary: temporary) { _, _ in }
        }.value
        try require(inventory.errors.isEmpty, "valid owned directories must scan")
        let measured = inventory.books.first { $0.id == onlineID }!
        try require(measured.chapters.count == 1 && measured.chapters[0].pages == 2, "only completed chapters are removable")
        try require(measured.chapterBytes == Int64(375 + marker.count), "partial downloads must still count toward storage")
        try require(inventory.books.first { $0.id == localID }?.bytes == 500, "local originals must be measured")
        try require(inventory.coverBytes == 120 && inventory.covers.count == 1, "exclude staging covers and symlink targets from cleanup")
        try require(inventory.backupBytes == 50 && inventory.externalBackupBytes == 45, "backup scope must exclude unrelated files")
        try require(inventory.temporaryBytes == 70, "shared temporary files are measured")

        try require(ComicStorage.canRemove(chapterURL: chapterURL, book: online, unfinished: [], excludedCategories: [], allowBookmarks: false), "ordinary completed chapter is removable")
        try require(!ComicStorage.canRemove(chapterURL: chapterURL, book: local, unfinished: [], excludedCategories: [], allowBookmarks: true), "local original must never be removable")
        try require(!ComicStorage.canRemove(chapterURL: chapterURL, book: online, unfinished: [chapterURL], excludedCategories: [], allowBookmarks: true), "unfinished task must be protected")
        online.categories = ["保留"]
        try require(!ComicStorage.canRemove(chapterURL: chapterURL, book: online, unfinished: [], excludedCategories: ["保留"], allowBookmarks: true), "excluded category must be protected")
        online.categories = nil
        online.chapters = [ChapterProgress(url: chapterURL, title: "第一话", pageCount: 2, lastPage: 1, completed: true, bookmarked: true)]
        try require(!ComicStorage.canRemove(chapterURL: chapterURL, book: online, unfinished: [], excludedCategories: [], allowBookmarks: false), "chapter bookmark must be protected")
        online.chapters = nil
        online.bookmarks = [ComicBookmark(page: 0, title: "书签", chapterURL: chapterURL)]
        try require(!ComicStorage.canRemove(chapterURL: chapterURL, book: online, unfinished: [], excludedCategories: [], allowBookmarks: false), "page bookmark must be protected")
        try require(ComicStorage.canRemove(chapterURL: chapterURL, book: online, unfinished: [], excludedCategories: [], allowBookmarks: true), "explicit bookmark setting permits file cleanup")

        // Real filesystem cleanup uses the scanned list; a changed cover is
        // skipped, then the original snapshot remains unable to remove it.
        try write(completedCover, 81)
        try require(try ComicStorage.remove(inventory.covers, from: covers) == 0, "changed files must survive")
        try require(try ComicStorage.remove(Array(inventory.backups.dropFirst()), from: backups) == 1, "only older default backup is removed")
        try require(!manager.fileExists(atPath: oldest.path) && manager.fileExists(atPath: latest.path), "latest backup must survive")
        try require(manager.fileExists(atPath: stagingCover.path) && manager.fileExists(atPath: outside.path), "staging files and linked targets must survive")
        try require(manager.fileExists(atPath: root.appendingPathComponent(localID + "/comic.pdf").path)
                    && manager.fileExists(atPath: root.appendingPathComponent("library.json").path)
                    && manager.fileExists(atPath: onlineFolder.appendingPathComponent("manga.json").path)
                    && manager.fileExists(atPath: backups.appendingPathComponent("unrelated.txt").path)
                    && manager.fileExists(atPath: temporary.appendingPathComponent("active-import.pdf").path), "originals, metadata, unrelated and active temporary files must survive")
        let forged = ComicStorageFile(url: outside, bytes: 90, modified: nil)
        do { _ = try ComicStorage.remove([forged], from: covers); throw Failure("outside-root deletion accepted") }
        catch is Failure { throw Failure("outside-root deletion accepted") }
        catch { }
        try manager.removeItem(at: chapter)
        try manager.createSymbolicLink(at: chapter, withDestinationURL: sandbox)
        do { try ComicStorage.validateChapter(root: root, bookID: onlineID, chapterURL: chapterURL); throw Failure("linked chapter accepted") }
        catch is Failure { throw Failure("linked chapter accepted") }
        catch { }
        print("PASS: off-main scan, complete/partial/image counts, protected categories/bookmarks/tasks, owned cleanup, changed files, symlink boundaries, originals/metadata/latest backup preserved")
    }

    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private static func requireBackgroundThread() throws { try require(!Thread.isMainThread, "scan must run off the main thread") }
}
