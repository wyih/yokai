#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import ZIPFoundation

// The simulator cannot execute the upstream mobile JVM reliably. This explicit
// launch argument is only for checking the native screens against local fixtures.
enum LocalUIFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiLocalUIFixture") }
    private static var root: URL { YokaiStorage.documents.appendingPathComponent("UIFixture") }
    @MainActor private static var activeImages = 0
    @MainActor private static var maxImages = 0
    @MainActor private static var imageRequests: [Int: Int] = [:]
    @MainActor private static var pageRequests = 0
    @MainActor private static var failImageOnce = false
    @MainActor static func response(_ action: String, _ arguments: [String: Any]) async throws -> Any {
        let details = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("details.json"))) as! [String: Any]
        switch action {
        case "load":
            var sources = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("sources.json"))) as! [[String: Any]]
            if ProcessInfo.processInfo.arguments.contains("-YokaiLocalDownloadCheck") {
                sources += (0..<5).map { ["id": "fixture-download-\($0)", "name": "本地并发验证\($0)", "lang": "zh", "latest": false, "package": "fixture.download"] as [String: Any] }
            }
            return sources
        case "details": return details
        case "popular", "latest", "search": return ["manga": [details["manga"]!], "hasNext": false]
        case "filters": return try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("filters.json")))
        case "webViewInfo": return ["url": "https://example.org", "headers": [String: String]()]
        case "preferences":
            if LocalPerformanceCheck.enabled || previewScreen == "source-settings" {
                return [["index": 0, "key": "username", "title": "用户名", "value": "", "valueType": "string"],
                        ["index": 1, "key": "password", "title": "密码", "value": "", "valueType": "string"],
                        ["index": 2, "key": "domain", "title": "域名", "value": "example.org", "valueType": "string"]]
            }
            return [Any]()
        case "setPreference": return true
        case "pages":
            guard (arguments["chapter"] as? [String: Any])?["url"] as? String == "/fixture-download/chapter" else { throw SourceError.message("此验证仅使用本地下载章节。") }
            pageRequests += 1
            return (0..<4).map { ["index": 10 + $0, "url": "/fixture-download/page/\($0)", "imageURL": "https://example.org/\($0).png"] as [String: Any] }
        case "image":
            guard let page = arguments["page"] as? [String: Any], let index = page["index"] as? Int,
                  let path = arguments["path"] as? String, path.contains("DownloadCheck") else { throw SourceError.message("此验证仅生成本地下载图片。") }
            activeImages += 1; maxImages = max(maxImages, activeImages); imageRequests[index, default: 0] += 1
            defer { activeImages -= 1 }
            try await Task.sleep(nanoseconds: index == 0 ? 300_000_000 : 90_000_000)
            if index == 2 && failImageOnce { failImageOnce = false; throw SourceError.message("图片下载失败（HTTP 403）") }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 40), format: format).image { context in
                UIColor(hue: CGFloat(index) / 4, saturation: 1, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 24, height: 40))
            }
            try image.pngData()!.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        default: throw SourceError.message("此本地界面验证不执行插件请求。")
        }
    }
    @MainActor static func checkDownloads(extensions: ExtensionStore) async {
        guard ProcessInfo.processInfo.arguments.contains("-YokaiLocalDownloadCheck") else { return }
        let output = root.appendingPathComponent("download-check.json")
        let folder = root.appendingPathComponent("DownloadCheck")
        let defaults = YokaiStorage.defaults
        let oldWifi = defaults.object(forKey: "downloads.wifiOnly"), oldCBZ = defaults.object(forKey: "downloads.saveCBZ")
        defaults.set(false, forKey: "downloads.wifiOnly"); defaults.set(true, forKey: "downloads.saveCBZ")
        defer {
            if let oldWifi { defaults.set(oldWifi, forKey: "downloads.wifiOnly") } else { defaults.removeObject(forKey: "downloads.wifiOnly") }
            if let oldCBZ { defaults.set(oldCBZ, forKey: "downloads.saveCBZ") } else { defaults.removeObject(forKey: "downloads.saveCBZ") }
        }
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            let library = ComicLibrary(root: folder.appendingPathComponent("Library"))
            let downloads = DownloadStore(directory: folder)
            downloads.connect(library: library, extensions: extensions)
            guard let source = extensions.sources.first else { throw SourceError.message("No fixture source") }
            let manga = SourceManga(url: "/fixture-download/book", title: "下载验证")
            let chapter = SourceChapter(url: "/fixture-download/chapter", name: "章节", number: 1, uploaded: 0)
            @MainActor func wait(_ name: String, _ condition: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(6)
                while !condition() {
                    if Date() > deadline { throw SourceError.message("Timed out: " + name) }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            activeImages = 0; maxImages = 0; pageRequests = 0; imageRequests = [:]
            let id = downloads.enqueue(source: source, manga: manga, chapter: chapter, userInitiated: false)
            try await wait("second image first") { downloads.jobs.first?.received == 1 }
            guard downloads.jobs.first?.completed == 0, maxImages == 2 else { throw SourceError.message("Out-of-order image exposed an unreadable first page, or images were serialized") }
            downloads.pause(id)
            try await wait("pause unwinding") { activeImages == 0 }
            downloads.foreground()
            guard downloads.jobs.first?.state == .paused, downloads.jobs.first?.error == nil else { throw SourceError.message("User pause was changed by foregrounding or an in-flight request") }
            let cachedRequests = imageRequests[1]
            downloads.resume(id, userInitiated: false)
            try await wait("resume") { downloads.jobs.first?.state == .completed }
            guard pageRequests == 1, imageRequests[1] == cachedRequests, downloads.jobs.first?.completed == 4 else { throw SourceError.message("Resume redownloaded a cached page/list, or lost contiguous progress") }
            let bookID = ComicLibrary.hash(source.id + "\n" + manga.url)
            let directory = library.chapterDirectory(bookID: bookID, chapterURL: chapter.url)
            guard ChapterArchive.hasCompleteArchive(directory: directory, count: 4), ChapterArchive.imageSize(directory: directory, index: 0)?.width == 24 else { throw SourceError.message("Completed CBZ is unreadable") }
            let requestsBeforeRecovery = imageRequests
            try FileManager.default.removeItem(at: directory.appendingPathComponent("chapter.json"))
            _ = downloads.enqueue(source: source, manga: manga, chapter: chapter, userInitiated: false)
            try await wait("archive recovery") { downloads.jobs.first?.state == .completed }
            guard imageRequests == requestsBeforeRecovery, pageRequests == 1 else { throw SourceError.message("A committed CBZ was downloaded again after interrupted finalization") }
            let restored = DownloadStore(directory: folder)
            guard restored.jobs.first?.state == .completed, restored.jobs.first?.received == 4 else { throw SourceError.message("Persistent download checkpoint changed") }
            let interruptedManga = SourceManga(url: "/fixture-download/interrupted", title: "后台中断")
            let interruptedID = downloads.enqueue(source: source, manga: interruptedManga, chapter: chapter, userInitiated: false)
            try await wait("background preparation") { downloads.jobs.first(where: { $0.id == interruptedID })?.total == 4 }
            downloads.interruptForBackground(.backgroundTime)
            guard downloads.jobs.first(where: { $0.id == interruptedID })?.interruption == .backgroundTime else { throw SourceError.message("Background expiration was not persisted before suspension") }
            try await wait("background unwinding") { activeImages == 0 }
            downloads.foreground()
            try await wait("foreground recovery") { downloads.jobs.first(where: { $0.id == interruptedID })?.state == .completed }
            let systemID = downloads.enqueue(source: source, manga: SourceManga(url: "/fixture-download/system", title: "系统停止"), chapter: chapter, userInitiated: false)
            try await wait("system preparation") { downloads.jobs.first(where: { $0.id == systemID })?.total == 4 }
            downloads.interruptForBackground(.system, ids: [systemID])
            try await wait("system unwinding") { activeImages == 0 }
            downloads.foreground()
            guard downloads.jobs.first(where: { $0.id == systemID })?.state == .paused else { throw SourceError.message("System/user cancellation resumed without a Resume action") }
            downloads.resume(systemID, userInitiated: false)
            try await wait("system resume") { downloads.jobs.first(where: { $0.id == systemID })?.state == .completed }
            let cancelID = downloads.enqueue(source: source, manga: SourceManga(url: "/fixture-download/cancel", title: "取消验证"), chapter: chapter, userInitiated: false)
            try await wait("cancel preparation") { downloads.jobs.first(where: { $0.id == cancelID })?.total == 4 }
            downloads.cancel(cancelID)
            try await wait("cancel unwinding") { activeImages == 0 }
            guard !downloads.jobs.contains(where: { $0.id == cancelID }) else { throw SourceError.message("Cancelled job returned after an in-flight image completed") }
            failImageOnce = true
            let failedManga = SourceManga(url: "/fixture-download/expired-url", title: "失效链接")
            let failedID = downloads.enqueue(source: source, manga: failedManga, chapter: chapter, userInitiated: false)
            try await wait("expired image URL") { downloads.jobs.first(where: { $0.id == failedID })?.state == .failed }
            let failedDirectory = library.chapterDirectory(bookID: ComicLibrary.hash(source.id + "\n" + failedManga.url), chapterURL: chapter.url)
            guard !FileManager.default.fileExists(atPath: failedDirectory.appendingPathComponent("pages.json").path) else { throw SourceError.message("Retry would reuse stale image URLs") }
            let oldPages = pageRequests, oldCachedImage = imageRequests[1]
            downloads.resume(failedID, userInitiated: false)
            try await wait("fresh URL retry") { downloads.jobs.first(where: { $0.id == failedID })?.state == .completed }
            guard pageRequests == oldPages + 1, imageRequests[1] == oldCachedImage else { throw SourceError.message("Retry did not refresh URLs while preserving successful images") }
            let concurrentSources = extensions.sources.filter { $0.id.hasPrefix("fixture-download-") }
            guard concurrentSources.count == 5 else { throw SourceError.message("Five local sources were not loaded") }
            let concurrentIDs = concurrentSources.enumerated().map { index, source in
                downloads.enqueue(source: source, manga: SourceManga(url: "/fixture-download/concurrent/\(index)", title: "并发\(index)"), chapter: chapter, userInitiated: false)
            }
            try await wait("five sources") { maxImages == 10 }
            try await wait("five source completion") { concurrentIDs.allSatisfy { id in downloads.jobs.first(where: { $0.id == id })?.state == .completed } }
            try JSONSerialization.data(withJSONObject: ["passed": true, "maxParallelImages": maxImages,
                "checks": ["two images in parallel with out-of-order completion", "user pause survives foreground", "page-list and image checkpoint reuse", "committed CBZ recovery", "persistent queue", "background timeout recovery", "system cancellation requires explicit resume", "cancel does not resurrect a job", "stale image URLs refresh on retry without discarding images", "five sources with two images each"]]).write(to: output, options: .atomic)
        } catch { try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription]).write(to: output, options: .atomic) }
    }
    @MainActor static func checkFiles(library: ComicLibrary, extensions: ExtensionStore) async {
        guard ProcessInfo.processInfo.arguments.contains("-YokaiLocalFileCheck") else { return }
        let output = root.appendingPathComponent("file-check.json")
        do {
            let folder = root.appendingPathComponent("ArchiveCheck")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var pixelWidths: [Int] = []
            for index in 0..<2 {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 17 + index, height: 31)).image { context in
                    (index == 0 ? UIColor.red : UIColor.blue).setFill(); context.fill(CGRect(x: 0, y: 0, width: 17 + index, height: 31))
                }
                pixelWidths.append(image.cgImage!.width)
                try image.pngData()!.write(to: folder.appendingPathComponent(String(format: "%06d", index)), options: .atomic)
            }
            let file = try ChapterArchive.create(directory: folder, count: 2)
            let archive = try Archive(url: file, accessMode: .read)
            guard Array(archive).count == 2 else { throw SourceError.message("CBZ entry count changed") }
            for index in 0..<2 { try FileManager.default.removeItem(at: folder.appendingPathComponent(String(format: "%06d", index))) }
            for index in 0..<2 {
                guard let image = ChapterArchive.image(directory: folder, index: index), image.cgImage?.width == pixelWidths[index] else { throw SourceError.message("CBZ reader failed after original images were removed") }
                guard ChapterArchive.imageSize(directory: folder, index: index)?.width == CGFloat(pixelWidths[index]) else { throw SourceError.message("CBZ image dimensions changed") }
            }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let spread = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 20), format: format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
                UIColor.blue.setFill(); context.fill(CGRect(x: 30, y: 0, width: 30, height: 20))
            }
            guard spread.spreadHalf(0).cgImage?.width == 30, spread.spreadHalf(1).cgImage?.width == 30,
                  spread.stackingSpread(rightFirst: true, gap: 15).cgImage?.height == 55 else { throw SourceError.message("Spread splitting dimensions changed") }
            func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: 4)
                bytes.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                    context.draw(image.cgImage!.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                return Array(bytes.prefix(3))
            }
            let stacked = spread.stackingSpread(rightFirst: true, gap: 15)
            guard pixel(spread.spreadHalf(0), 5, 5) == [255, 0, 0], pixel(spread.spreadHalf(1), 5, 5) == [0, 0, 255],
                  pixel(stacked, 5, 5) == [0, 0, 255], pixel(stacked, 5, 50) == [255, 0, 0] else { throw SourceError.message("Spread splitting changed reading order") }
            let readingRoot = folder.appendingPathComponent("ReadingCheck")
            if FileManager.default.fileExists(atPath: readingRoot.path) { try FileManager.default.removeItem(at: readingRoot) }
            let reading = ComicLibrary(root: readingRoot)
            let source = extensions.sources[0]
            let saved = reading.addOnline(SourceManga(url: "/reading/check", title: "进度检查"), source: source)
            let chapter = SourceChapter(url: "/reading/chapter", name: "章节", number: 1, uploaded: 0)
            _ = reading.openChapter(chapter, pages: 1, bookID: saved.id)
            reading.setPage(0, for: saved.id, finished: false)
            guard reading.books[0].chapters?.first?.completed == false else { throw SourceError.message("First half was prematurely marked read") }
            reading.setPage(0, for: saved.id, finished: true)
            guard reading.books[0].chapters?.first?.completed == true else { throw SourceError.message("Last split half did not complete the chapter") }
            reading.setPage(0, for: saved.id, finished: false)
            guard reading.books[0].chapters?.first?.completed == true else { throw SourceError.message("Re-reading cleared completed chapter state") }
            _ = reading.openChapter(chapter, pages: 3, bookID: saved.id)
            reading.setPage(2, for: saved.id, finished: true)
            guard reading.openChapter(chapter, pages: 3, bookID: saved.id)?.lastPage == 0,
                  reading.books[0].chapters?.first?.completed == true else { throw SourceError.message("Completed chapter did not reopen from the first page") }
            let data = try await NativeBackup.export(library: library, extensions: extensions, appPreferences: true, sourcePreferences: false)
            let backup = try JSONDecoder().decode(NativeShelfBackup.self, from: data)
            guard backup.shelf == library.snapshot(), backup.preferences != nil else { throw SourceError.message("Native backup omitted shelf or preferences") }
            let settings = try NativeBackup.preferences(backup.preferences!)
            guard !settings.keys.contains(where: { $0.hasPrefix("webdav") }) else { throw SourceError.message("Unexpected sync credentials in app preferences") }
            let exported = folder.appendingPathComponent("native.json"); try data.write(to: exported, options: .atomic)
            let restored = ComicLibrary(root: folder.appendingPathComponent("Restored"))
            try await AndroidBackupService.restore(exported, library: restored, extensions: extensions, appPreferences: false, sourcePreferences: false)
            guard restored.books.count == library.books.count,
                  Set(restored.books.map(\.id)) == Set(library.books.map(\.id)) else { throw SourceError.message("Native shelf restore changed book identities") }
            for book in library.books where library.cachedDetails(for: book) != nil {
                guard restored.cachedDetails(for: book)?.chapters == library.cachedDetails(for: book)?.chapters else { throw SourceError.message("Native restore lost the chapter list/order") }
            }
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": ["CBZ extraction/dimensions after deleting original image files", "spread splitting", "split completion and completed chapter rereading", "native shelf/settings export", "native backup restore with chapter order"]]).write(to: output, options: .atomic)
        } catch { try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription]).write(to: output, options: .atomic) }
    }
    @MainActor static func checkTachimanga(extensions: ExtensionStore) async {
        guard ProcessInfo.processInfo.arguments.contains("-YokaiTachimangaCheck") else { return }
        let output = root.appendingPathComponent("tachimanga-check.json")
        do {
            let input = root.appendingPathComponent("tachimanga.tmb")
            let backup = try TachimangaBackup.read(input)
            let state = backup.shelf
            let chapters = state.books.flatMap { $0.chapters ?? [] }
            guard state.books.count == 76, state.books.filter({ $0.inLibrary == true }).count == 45,
                  chapters.count == 4048, chapters.filter(\.completed).count == 79,
                  state.books.filter({ $0.lastRead != nil }).count == 59,
                  backup.sourcePreferences?.count == 8 else { throw SourceError.message("Tachimanga counts changed") }
            let book = state.books.first { $0.origin?.mangaURL == "/book/47471" }!
            let chapter = book.chapters!.first { $0.url == "/chapter/31304351" }!
            guard chapter.lastPage == 74, chapter.pageCount == 76,
                  chapter.lastRead == Date(timeIntervalSince1970: 1773412957),
                  backup.details?[book.id]?.chapters.map(\.url) == book.chapters?.map(\.url) else { throw SourceError.message("Tachimanga progress/date/chapter order changed") }
            let folder = root.appendingPathComponent("TachimangaCheck")
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            let restored = ComicLibrary(root: folder)
            var existing = book
            existing.inLibrary = true
            existing.chapters![0].bookmarked = true
            existing.chapters![0].completed = true
            restored.acceptSync(ShelfState(books: [existing]), captured: restored.snapshot())
            try await AndroidBackupService.restore(input, library: restored, extensions: extensions, appPreferences: false, sourcePreferences: false)
            guard restored.books.count == 76, let imported = restored.books.first(where: { $0.id == book.id }),
                  imported.inLibrary == true, imported.chapters?.first(where: { $0.url == existing.chapters![0].url })?.bookmarked == true,
                  imported.chapters?.first(where: { $0.url == existing.chapters![0].url })?.completed == true,
                  restored.cachedDetails(for: imported)?.chapters.map(\.url) == backup.details?[book.id]?.chapters.map(\.url) else { throw SourceError.message("Tachimanga merge lost existing shelf/bookmark/read state or chapter cache") }
            try await AndroidBackupService.restore(input, library: restored, extensions: extensions, appPreferences: false, sourcePreferences: false)
            guard restored.books.count == 76 else { throw SourceError.message("Repeated Tachimanga import duplicated books") }
            let converted = root.appendingPathComponent("Tachimanga-Yokai.json")
            try JSONEncoder().encode(backup).write(to: converted, options: .atomic)
            try JSONSerialization.data(withJSONObject: ["passed": true, "books": 76, "shelf": 45, "chapters": 4048, "readChapters": 79, "historyBooks": 59, "sourcePreferences": 8,
                "checks": ["original TMB ZIP/database", "64-bit source IDs", "74/76 progress and seconds/milliseconds", "cached chapter order", "merge preserves existing favorites/bookmarks/read state", "repeat import without duplicates"]]).write(to: output, options: .atomic)
        } catch { try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription]).write(to: output, options: .atomic) }
    }
}
#endif
