#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit

enum LocalPerformanceCheck {
    static var enabled: Bool { LocalUIFixture.enabled && ProcessInfo.processInfo.arguments.contains("-YokaiPerformanceCheck") }

    @MainActor static func run() async {
        guard enabled else { return }
        let root = YokaiStorage.documents.appendingPathComponent("UIFixture")
        let folder = root.appendingPathComponent("PerformanceCheck")
        do {
            let backup = try await Task.detached { try TachimangaBackup.read(root.appendingPathComponent("tachimanga.tmb")) }.value
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            let library = ComicLibrary(root: folder)
            library.acceptSync(backup.shelf, captured: library.snapshot())
            for (id, details) in backup.details ?? [:] { try library.cacheImportedDetails(details, bookID: id) }
            try await library.flushPendingSaves()
            let shelf = library.books.filter { $0.inLibrary != false }
            await library.refreshDownloadedChapters(bookIDs: Set(shelf.map(\.id)))
            func milliseconds(_ work: () throws -> Void) rethrows -> Double {
                let start = ProcessInfo.processInfo.systemUptime; try work()
                return (ProcessInfo.processInfo.systemUptime - start) * 1000
            }
            // The former UI path, kept here solely to measure the reported regression.
            func previousMetrics() throws -> [String: ShelfBookMetrics] {
                try Dictionary(uniqueKeysWithValues: shelf.map { book in
                    let data = try Data(contentsOf: folder.appendingPathComponent(book.id).appendingPathComponent("manga.json"))
                    let chapters = try JSONDecoder().decode(SourceDetails.self, from: data).chapters
                    let count = book.mangaInfo?.chapterCount ?? chapters.count
                    let available = chapters.filter { FileManager.default.fileExists(atPath: library.chapterDirectory(bookID: book.id, chapterURL: $0.url).appendingPathComponent("chapter.json").path) }.count
                    return (book.id, ShelfBookMetrics(chapters: count, unread: max(0, count - (book.chapters ?? []).filter(\.completed).count), downloaded: available, latest: book.mangaInfo?.latestUpload ?? chapters.map(\.uploaded).max() ?? 0))
                })
            }
            let expected = try previousMetrics()
            guard expected == library.shelfMetrics() else { throw SourceError.message("Cached shelf statistics changed") }
            var oldMetrics: [Double] = [], newMetrics: [Double] = []
            for _ in 0..<15 {
                oldMetrics.append(try milliseconds { _ = try previousMetrics() })
                newMetrics.append(milliseconds { _ = library.shelfMetrics() })
            }
            let book = library.books.first { $0.origin?.mangaURL == "/book/47471" }!
            let chapter = backup.details![book.id]!.chapters.first { $0.url == "/chapter/31304351" }!
            _ = library.openChapter(chapter, pages: 100, bookID: book.id)
            try await library.flushPendingSaves()
            let writes = library.storageWrites
            var oldSaves: [Double] = [], newPages: [Double] = []
            let oldFile = folder.appendingPathComponent("previous-save.json")
            for page in 0..<50 {
                oldSaves.append(try milliseconds { try JSONEncoder().encode(library.snapshot()).write(to: oldFile, options: .atomic) })
                newPages.append(milliseconds { library.setPage(page, for: book.id, finished: false) })
            }
            try await library.flushPendingSaves()
            let saved = ComicLibrary(root: folder)
            guard saved.snapshot() == library.snapshot(), saved.books.first(where: { $0.id == book.id })?.lastPage == 49,
                  library.storageWrites - writes == 1 else { throw SourceError.message("Coalesced reading progress was lost or written out of order") }
            library.setPage(50, for: book.id)
            library.rename(book.id, title: book.title + " · local check")
            try await library.flushPendingSaves()
            guard ComicLibrary(root: folder).snapshot() == library.snapshot() else { throw SourceError.message("A pending page overwrote a later title change") }
            let beforeTimer = library.storageWrites
            library.setPage(51, for: book.id)
            try await Task.sleep(nanoseconds: 450_000_000)
            try await library.flushPendingSaves()
            guard library.storageWrites == beforeTimer + 1, ComicLibrary(root: folder).books.first(where: { $0.id == book.id })?.lastPage == 51 else { throw SourceError.message("Debounced autosave did not persist its last page") }
            let invalidFile = folder.appendingPathComponent("write-failure")
            try FileManager.default.createDirectory(at: invalidFile, withIntermediateDirectories: true)
            let failingWriter = JSONFileWriter<ShelfState>(file: invalidFile)
            failingWriter.write(library.snapshot()) { _ in }
            var failed = false
            do { try await failingWriter.flush() } catch { failed = true }
            guard failed else { throw SourceError.message("Asynchronous write failure was silently ignored") }
            let downloaded = backup.details![book.id]!.chapters[0]
            let directory = library.chapterDirectory(bookID: book.id, chapterURL: downloaded.url)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(CachedChapter(chapter: downloaded, pageCount: 5)).write(to: directory.appendingPathComponent("chapter.json"))
            await library.refreshDownloadedChapters(bookIDs: [book.id])
            guard library.isChapterDownloaded(bookID: book.id, chapterURL: downloaded.url) else { throw SourceError.message("Existing downloads were not indexed") }
            library.downloadedChapterChanged(bookID: book.id, chapterURL: downloaded.url, available: false)
            guard !library.isChapterDownloaded(bookID: book.id, chapterURL: downloaded.url) else { throw SourceError.message("Deleted download remains in cached statistics") }
            library.downloadedChapterChanged(bookID: book.id, chapterURL: downloaded.url, available: true)
            guard library.shelfMetrics()[book.id]?.downloaded == 1 else { throw SourceError.message("Completed download count was not updated") }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 540), format: format).image { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 360, height: 540)) }
            library.changeCover(book.id, image: image)
            let first = await library.loadCover(for: book), second = await library.loadCover(for: book)
            guard first != nil, first === second else { throw SourceError.message("Cover memory cache was not reused") }
            let revision = library.coverRevisions[book.id]
            library.changeCover(book.id, image: image)
            guard library.coverRevisions[book.id] != revision, library.cover(for: book) == nil,
                  await library.loadCover(for: book) != nil else { throw SourceError.message("Changing a cover did not invalidate the cache") }
            func summary(_ samples: [Double]) -> [String: Double] {
                let ordered = samples.sorted()
                return ["medianMS": ordered[ordered.count / 2], "p95MS": ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))]]
            }
            let report: [String: Any] = ["passed": true, "environment": "iPhone Air iOS 27 simulator, Debug, local TMB data", "shelfBooks": shelf.count,
                "chapterRecords": backup.shelf.books.reduce(0) { $0 + ($1.chapters?.count ?? 0) }, "previousShelfRefresh": summary(oldMetrics), "currentShelfRefresh": summary(newMetrics),
                "previousWholeShelfSave": summary(oldSaves), "currentPageUpdate": summary(newPages), "writesFor50Pages": 1,
                "checks": ["same shelf statistics", "final page survives reload", "ordered saves preserve later edits", "debounced autosave", "write failures propagate", "existing/downloaded/deleted chapters update counts", "cover cache reuse and invalidation"]]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("performance-check.json"), options: .atomic)
        } catch { try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription]).write(to: root.appendingPathComponent("performance-check.json"), options: .atomic) }
    }
}
#endif
