#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import WebKit
import ZIPFoundation

// The simulator cannot execute the upstream mobile JVM reliably. This explicit
// launch argument is only for checking the native screens against local fixtures.
enum LocalUIFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiLocalUIFixture") }
    private static var root: URL { YokaiStorage.documents.appendingPathComponent("UIFixture") }
    private static var metadataCheck: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiMetadataCheck") }
    private static var metadataFeaturesCheck: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiMetadataFeaturesCheck") }
    private static var sourceFilterCheck: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiLibrarySourceFilterCheck") }
    private static var readerCheck: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiReaderInteractionCheck") }
    private static var readerImageCheck: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiReaderImageCheck") }
    private static var historyCheck: Bool { ProcessInfo.processInfo.arguments.contains("-YokaiHistoryBatchCheck") }
    private static let metadataManga = SourceManga(
        url: "/metadata/full",
        title: "复制验证：在遥远星空下与伙伴一起寻找失落书页的漫长旅程——这是一段超过详情标题显示行数的完整标题，包含空格 Full Title & 最后不能遗漏的尾声",
        author: "作者甲 / Author A", artist: "画师乙 / Artist B",
        description: "简介第一段：可选择并复制的完整文字。\n简介第二段：保留换行与标点。")
    private static let emptyMetadataManga = SourceManga(url: "/metadata/empty", title: "空元数据验证", author: "")
    private static let featureManga = SourceManga(url: "/metadata/features", title: "详情组合验证",
        author: "作者甲 / Author A", artist: "画师乙 / Artist B", genre: "冒险， 科幻\n冒险")
    private static let featureColdManga = SourceManga(url: "/metadata/features-cold", title: "无缓存验证")
    private static let imageManga = SourceManga(url: "/reader-image/book", title: "坏图与文字验证")
    private static let imageChapter = SourceChapter(url: "/reader-image/chapter", name: "修复验证章节", number: 1, uploaded: 0)
    @MainActor private static var featureDetailsRequests: [String: Int] = [:]
    @MainActor private static var activeImages = 0
    @MainActor private static var maxImages = 0
    @MainActor private static var imageRequests: [Int: Int] = [:]
    @MainActor private static var pageRequests = 0
    @MainActor private static var failImageOnce = false
    @MainActor private static var coverRequests = 0
    @MainActor private static var coverVerified = false
    @MainActor private static var failCookieSync = false
    @MainActor static func response(_ action: String, _ arguments: [String: Any]) async throws -> Any {
        if readerImageCheck {
            switch action {
            case "load": return [["id": "reader-image", "name": "图片验证图源", "lang": "zh", "package": "fixture.reader.image"]]
            case "details": return try SourceEngine.object(SourceDetails(manga: imageManga, chapters: [imageChapter]))
            case "filters": return [Any]()
            case "popular", "latest": return ["manga": [try SourceEngine.object(imageManga)], "hasNext": false]
            case "webViewInfo": return ["url": "https://example.org/reader-image", "headers": [String: String]()]
            case "pages": return [["index": 0, "url": "/reader-image/page", "imageURL": "https://example.org/reader-image.png"]]
            case "image":
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360), format: format).image { context in
                    UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
                }
                try image.pngData()!.write(to: URL(fileURLWithPath: arguments["path"] as! String), options: .atomic)
                return true
            default: throw SourceError.message("坏图验证不执行其他插件请求。")
            }
        }
        if metadataFeaturesCheck {
            switch action {
            case "load":
                return (0..<4).map { ["id": "metadata-features-\($0)", "name": "详情验证图源\($0)", "lang": "zh", "package": "fixture.metadata.\($0)"] }
            case "filters": return [Any]()
            case "popular", "latest":
                return ["manga": try [featureManga, featureColdManga].map { try SourceEngine.object($0) }, "hasNext": false]
            case "details":
                let input = arguments["manga"] as? [String: Any] ?? [:]
                var manga = input["url"] as? String == featureColdManga.url ? featureColdManga : featureManga
                let key = (arguments["source"] as? String ?? "") + "\n" + manga.url
                featureDetailsRequests[key, default: 0] += 1
                manga.description = "详情请求次数：\(featureDetailsRequests[key]!)"
                let chapters = [("a", "甲组章节", "汉化组甲"), ("b", "乙组章节", "汉化组乙"),
                                ("c", "丙组章节", "汉化组丙"), ("unknown", "未标注章节", "")].enumerated().map { index, item in
                    SourceChapter(url: manga.url + "/" + item.0, name: item.1, number: Double(index + 1), uploaded: 0, scanlator: item.2)
                }
                return try SourceEngine.object(SourceDetails(manga: manga, chapters: chapters))
            case "search":
                let source = arguments["source"] as? String ?? ""
                let query = arguments["query"] as? String ?? ""
                return ["manga": [["url": "/\(query)/\(source)", "title": "\(query)-\(source)"]], "hasNext": false]
            case "webViewInfo": return ["url": "https://example.org/metadata", "headers": [String: String]()]
            default: throw SourceError.message("详情组合验证不执行其他插件请求。")
            }
        }
        if readerCheck || historyCheck {
            if action == "load" { return [Any]() }
            throw SourceError.message("阅读与历史验证仅使用本地漫画。")
        }
        if ProcessInfo.processInfo.arguments.contains("-YokaiSourceNavigationCheck") {
            switch action {
            case "load":
                let items = arguments["extensions"] as! [[String: Any]]
                return (0..<3).map { ["id": "navigation-\($0)", "name": "配置验证图源\($0)", "lang": "zh",
                                     "package": items[$0 < 2 ? 0 : 1]["package"]!] }
            case "filters": return [Any]()
            case "popular", "latest": return ["manga": [["url": "/navigation/book", "title": "图源目录验证"]], "hasNext": false]
            case "preferences":
                return [["index": 0, "key": "username", "title": "用户名", "value": "", "valueType": "string"],
                        ["index": 1, "key": "password", "title": "密码", "value": "", "valueType": "string"]]
            default: throw SourceError.message("此入口验证不执行其他插件请求。")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-YokaiCoverCacheCheck") {
            switch action {
            case "load": return [["id": "cover-check", "name": "封面验证", "lang": "zh", "package": "fixture.cover"]]
            case "webViewInfo": return ["url": "https://cover-check.invalid/", "headers": ["User-Agent": "Yokai-Cover-Check"]]
            case "exportCookies": return [Any]()
            case "cookies":
                if failCookieSync { throw SourceError.message("模拟 Cookie 同步失败") }
                let cookies = arguments["cookies"] as? [[String: Any]] ?? []
                coverVerified = (arguments["hosts"] as? [String])?.contains("cover-check.invalid") == true
                    && cookies.contains { ($0["name"] as? String) == "cover-check-clearance" && ($0["value"] as? String) == "verified" }
                return true
            case "cover":
                coverRequests += 1
                guard coverVerified else { throw SourceError.message("请在 WebView 中完成网站验证，点完成后重试。") }
                let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 40)).image { context in
                    UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 40))
                }
                try image.pngData()!.write(to: URL(fileURLWithPath: arguments["path"] as! String))
                return true
            default: throw SourceError.message("此封面验证不执行其他插件请求。")
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-YokaiGlobalSearchCheck") || metadataCheck || sourceFilterCheck {
            switch action {
            case "load":
                return (0..<6).map { ["id": "search-\($0)", "name": "搜索验证图源\($0)", "lang": "zh", "package": "fixture.search.\($0)"] }
            case "filters", "popular", "latest":
                if action == "filters" { return [Any]() }
                if metadataCheck {
                    return ["manga": try [metadataManga, emptyMetadataManga].map { try SourceEngine.object($0) }, "hasNext": false]
                }
                return ["manga": [Any](), "hasNext": false]
            case "details":
                let manga = arguments["manga"] as? [String: Any] ?? [:]
                let information = manga["url"] as? String == emptyMetadataManga.url ? emptyMetadataManga : metadataManga
                return ["manga": try SourceEngine.object(information), "chapters": [Any]()]
            case "webViewInfo": return ["url": "https://example.org/metadata", "headers": [String: String]()]
            case "search":
                let source = arguments["source"] as? String ?? ""
                let query = arguments["query"] as? String ?? ""
                if source == "search-0" && !metadataCheck {
                    // The Java bridge may finish after its Swift task was cancelled.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { continuation.resume() }
                    }
                }
                if source == "search-2" { throw SourceError.message("测试图源连接失败") }
                return ["manga": [["url": "/\(query)/\(source)", "title": "\(query)-\(source)"]], "hasNext": false]
            default: throw SourceError.message("此搜索验证不执行插件请求。")
            }
        }
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
    @MainActor static func checkCovers(extensions: ExtensionStore) async {
        guard ProcessInfo.processInfo.arguments.contains("-YokaiCoverCacheCheck"), let source = extensions.sources.first else { return }
        let output = YokaiStorage.documents.appendingPathComponent("cover-check.json")
        do {
            let url = "https://cover-check.invalid/\(UUID().uuidString).png"
            var rejected = false
            do { _ = try await SourceCoverCache.load(source: source, url: url) } catch { rejected = true }
            guard rejected, SourceCoverCache.shared.errors[source.id]?[url] != nil else { throw SourceError.message("A failed cover must expose its error") }
            let session = SourceWebSession()
            await session.prepare(source: source, address: URL(string: url), manga: nil)
            let cookie = HTTPCookie(properties: [.domain: "cover-check.invalid", .path: "/", .name: "cover-check-clearance", .value: "verified", .secure: "TRUE"])!
            let store = session.webView.configuration.websiteDataStore.httpCookieStore
            await store.setCookie(cookie)
            let revision = SourceCoverCache.shared.revisions[source.id, default: 0]
            failCookieSync = true
            let failed = await session.finish()
            guard !failed, SourceCoverCache.shared.revisions[source.id, default: 0] == revision else { throw SourceError.message("Failed cookie sync must not trigger a cover retry") }
            failCookieSync = false
            let finished = await session.finish()
            await store.deleteCookie(cookie)
            guard finished, coverVerified, SourceCoverCache.shared.revisions[source.id, default: 0] == revision + 1 else { throw SourceError.message("WebView completion must sync cookies and trigger a retry") }
            let image = try await SourceCoverCache.load(source: source, url: url)
            let cached = try await SourceCoverCache.load(source: source, url: url)
            guard image === cached, coverRequests == 2, SourceCoverCache.shared.errors[source.id]?[url] == nil else { throw SourceError.message("Verified cover must decode, clear its error and reuse its cache") }
            _ = try await SourceCoverCache.load(source: source, url: url, refresh: true)
            guard coverRequests == 3 else { throw SourceError.message("Explicit refresh must request a new cover") }
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": ["cover errors are visible", "failed cookie sync does not retry", "WebView cookies reach the plugin", "verification completion triggers retry", "verified cover decodes and caches", "explicit refresh reloads"]]).write(to: output, options: .atomic)
        } catch { try? JSONSerialization.data(withJSONObject: ["passed": false, "error": error.localizedDescription]).write(to: output, options: .atomic) }
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
        if ProcessInfo.processInfo.arguments.contains("-YokaiAnimationCheck") {
            do { try ReaderAnimationChecks.prepare(library: library) }
            catch { library.errorMessage = error.localizedDescription }
        }
        if readerImageCheck, let source = extensions.sources.first(where: { $0.id == "reader-image" }) {
            do {
                for book in library.books where book.origin?.sourceID == source.id { library.remove(book) }
                let book = library.addOnline(imageManga, source: source)
                library.saveDetails(SourceDetails(manga: imageManga, chapters: [imageChapter]), source: source)
                library.setReaderSettings(MangaReaderSettings(mode: "webtoon", trimBorders: false, layout: "single"), bookID: book.id)
                _ = library.openChapter(imageChapter, pages: 1, bookID: book.id)
                let directory = library.chapterDirectory(bookID: book.id, chapterURL: imageChapter.url)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("not an image".utf8).write(to: directory.appendingPathComponent("000000"), options: .atomic)
                try JSONEncoder().encode(CachedChapter(chapter: imageChapter, pageCount: 1))
                    .write(to: directory.appendingPathComponent("chapter.json"), options: .atomic)
                YokaiStorage.defaults.set(true, forKey: "reader.longTap")
            } catch { library.errorMessage = error.localizedDescription }
        }
        if metadataFeaturesCheck, let source = extensions.sources.first(where: { $0.id == "metadata-features-1" }) {
            for book in library.books where book.origin?.sourceID.hasPrefix("metadata-features-") == true {
                library.remove(book)
            }
            let defaults = YokaiStorage.defaults
            defaults.set(true, forKey: SourceDetailsRefreshPolicy.enabledKey)
            defaults.set(SourceDetailsRefreshPolicy.defaultInterval, forKey: SourceDetailsRefreshPolicy.intervalKey)
            defaults.set(["metadata-features-3"], forKey: "sources.pinned")
            defaults.set(false, forKey: "sources.searchPinnedOnly")
            defaults.set("", forKey: "library.defaultCategory")
            for manga in [featureManga] {
                let book = library.addOnline(manga, source: source, favorite: false)
                defaults.removeObject(forKey: "chapters.display." + book.id)
                defaults.removeObject(forKey: "cache.details.lastFetched." + book.id)
            }
            let captured = library.snapshot()
            var state = captured
            if let index = state.books.firstIndex(where: { $0.origin?.mangaURL == featureManga.url && $0.origin?.sourceID == source.id }) {
                state.books[index].lastRead = Date()
            }
            library.acceptSync(state, captured: captured)
        }
        if readerCheck || historyCheck {
            do { try prepareReaderAndHistory(library: library) }
            catch { library.errorMessage = error.localizedDescription }
        }
        if metadataCheck || sourceFilterCheck {
            let captured = library.snapshot()
            var state = captured
            let local = ComicBook(id: ComicLibrary.hash("metadata-local"), title: "复制验证本地漫画", format: .images, pageCount: 1, importedAt: Date())
            var missing = ComicBook(id: ComicLibrary.hash("metadata-uninstalled\n/metadata/missing"), title: "复制验证缺失图源漫画", format: .images, pageCount: 1, importedAt: Date())
            missing.origin = ComicOrigin(sourceID: "metadata-uninstalled", mangaURL: "/metadata/missing")
            for var book in [local, missing] {
                book.mangaInfo = MangaMetadata(author: metadataManga.author, artist: metadataManga.artist,
                                              chapterCount: 0, latestUpload: 0, fetchedAt: Date())
                state.books.removeAll { $0.id == book.id }
                state.books.append(book)
                state.deleted.removeValue(forKey: book.id)
            }
            library.acceptSync(state, captured: captured)
            if sourceFilterCheck {
                for source in extensions.sources where ["search-1", "search-3"].contains(source.id) {
                    _ = library.addOnline(SourceManga(url: "/source-filter/\(source.id)", title: "复制验证图源漫画-\(source.id)"), source: source)
                }
            }
        }
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
    @MainActor private static func prepareReaderAndHistory(library: ComicLibrary) throws {
        let captured = library.snapshot()
        var state = captured
        var fixtures: [ComicBook] = []
        if readerCheck {
            let defaults = YokaiStorage.defaults
            defaults.set(ReaderToolbarItem.defaults, forKey: "reader.toolbar.items")
            defaults.set(120.0, forKey: "autoScrollSpeed")
            defaults.set(true, forKey: "reader.holdToScroll")
            defaults.set(true, forKey: "reader.longTap")
            defaults.set(0, forKey: "reader.sidePadding")
            for mode in ["pager", "webtoon"] {
                defaults.set("default", forKey: "tapZones.\(mode).preset")
                defaults.set("none", forKey: "tapZones.\(mode).invert")
                defaults.set("columns", forKey: "tapZones.\(mode).layout")
                defaults.set(TapZones.defaults, forKey: "tapZones.\(mode).actions")
            }
            var book = ComicBook(id: ComicLibrary.hash("reader-interaction"), title: "阅读手势验证", format: .images, pageCount: 6, importedAt: Date())
            book.readerSettings = MangaReaderSettings(mode: "webtoon", trimBorders: false, layout: "single")
            let directory = library.directory(for: book)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            for index in 0..<book.pageCount {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360), format: format).image { context in
                    UIColor(hue: CGFloat(index) / 6, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
                    ("第 \(index + 1) 页" as NSString).draw(at: CGPoint(x: 20, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.white])
                }
                try image.pngData()!.write(to: directory.appendingPathComponent(String(format: "%06d", index)), options: .atomic)
            }
            fixtures.append(book)
        }
        if historyCheck {
            let now = Date()
            for index in 0..<65 {
                var book = ComicBook(id: ComicLibrary.hash("history-batch-\(index)"), title: String(format: "历史批次 %03d", index), format: .images, pageCount: 1, importedAt: now)
                book.lastRead = now.addingTimeInterval(-Double(index) * 60)
                book.inLibrary = false
                fixtures.append(book)
            }
        }
        let ids = Set(fixtures.map(\.id))
        state.books.removeAll { ids.contains($0.id) }
        state.books += fixtures
        library.acceptSync(state, captured: captured)
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
