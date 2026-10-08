import Foundation
import PDFKit
import UIKit
import ZIPFoundation
import CryptoKit

struct ShelfBookMetrics: Equatable {
    var chapters = 0
    var unread = 0
    var downloaded = 0
    var latest: Int64 = 0
}

enum ComicImport {
    static let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"])

    static func run(url: URL, root: URL) throws -> ComicBook {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block) }
        let id = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path) else { throw ImportError.alreadyImported }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let format: ComicBook.Format
            let count: Int
            let cover: UIImage?
            switch url.pathExtension.lowercased() {
            case "pdf":
                let destination = directory.appendingPathComponent("comic.pdf")
                try manager.copyItem(at: url, to: destination)
                guard let document = PDFDocument(url: destination), !document.isLocked,
                      document.pageCount > 0 else {
                    throw ImportError.invalidPDF
                }
                format = .pdf
                count = document.pageCount
                cover = document.page(at: 0)?.thumbnail(of: CGSize(width: 360, height: 540), for: .mediaBox)
            case "cbz", "zip":
                let archive = try Archive(url: url, accessMode: .read)
                let entries = archive.filter {
                    $0.type == .file && imageExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
                        && !$0.path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" })
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                guard !entries.isEmpty else { throw ImportError.noImages }
                var totalBytes: UInt64 = 0
                for (index, entry) in entries.enumerated() {
                    totalBytes += UInt64(entry.uncompressedSize)
                    guard entry.uncompressedSize <= 100 * 1024 * 1024,
                          totalBytes <= 2 * 1024 * 1024 * 1024 else { throw ImportError.tooLarge }
                    // Synthetic filenames keep all archive paths inside this book's directory.
                    let output = directory.appendingPathComponent(String(format: "%06d", index))
                    _ = try archive.extract(entry, to: output)
                    guard UIImage(contentsOfFile: output.path) != nil else { throw ImportError.invalidImage }
                }
                format = .images
                count = entries.count
                cover = UIImage(contentsOfFile: directory.appendingPathComponent("000000").path)
            default:
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { throw ImportError.unsupported }
                let output = directory.appendingPathComponent("000000")
                try manager.copyItem(at: url, to: output)
                guard let image = UIImage(contentsOfFile: output.path) else { throw ImportError.invalidImage }
                format = .images
                count = 1
                cover = image
            }
            if let image = cover?.preparingThumbnail(of: CGSize(width: 360, height: 540)),
               let data = image.jpegData(compressionQuality: 0.8) {
                try data.write(to: directory.appendingPathComponent("cover.jpg"), options: .atomic)
            }
            return ComicBook(id: id, title: url.deletingPathExtension().lastPathComponent,
                             format: format, pageCount: count, importedAt: Date())
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    enum ImportError: LocalizedError {
        case invalidPDF, noImages, tooLarge, invalidImage, unsupported, alreadyImported
        var errorDescription: String? {
            switch self {
            case .invalidPDF: "无法打开此 PDF，请检查文件是否损坏或受密码保护。"
            case .noImages: "压缩包中没有可阅读的图片。"
            case .tooLarge: "压缩包解压后过大，请拆分为较小的卷后导入。"
            case .invalidImage: "漫画中有无法读取的图片，请检查文件。"
            case .unsupported: "请选择 CBZ、ZIP、PDF 或图片文件。"
            case .alreadyImported: "这份漫画已经导入书架。"
            }
        }
    }
}

@MainActor
final class ComicLibrary: ObservableObject {
    @Published private(set) var books: [ComicBook] = []
    @Published var errorMessage: String?
    @Published var importing = false
    @Published private(set) var changeCount = 0
    private(set) var deleted: [String: Date] = [:]
    @Published private(set) var categories: [ShelfCategory] = []
    @Published private(set) var downloadedChapters: [String: Set<String>] = [:]
    @Published private(set) var coverRevisions: [String: Int] = [:]
    let root: URL
    private let metadata: URL
    private var loaded = true
    private let writer: JSONFileWriter<ShelfState>
    private var pendingSave: Task<Void, Never>?
    private var detailsCache: [String: SourceDetails] = [:]
    private let coverCache = NSCache<NSString, UIImage>()
    private var coverLoads: [String: (revision: Int, task: Task<UIImage?, Never>)] = [:]
    private var downloadRevisions: [String: Int] = [:]
    #if DEBUG
    private(set) var storageWrites = 0
    #endif

    init(root: URL? = nil) {
        let manager = FileManager.default
        self.root = root ?? manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Comics", isDirectory: true)
        metadata = root != nil ? self.root.appendingPathComponent("library.json") :
            manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("library.json")
        writer = JSONFileWriter(file: metadata)
        coverCache.totalCostLimit = 32 * 1024 * 1024
        do {
            try manager.createDirectory(at: self.root, withIntermediateDirectories: true)
            try manager.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: metadata.path) {
                let state = try JSONDecoder().decode(ShelfState.self, from: Data(contentsOf: metadata))
                try ShelfMerge.validate(state)
                books = state.books
                deleted = state.deleted
                categories = state.categories ?? []
            }
        } catch {
            loaded = false
            errorMessage = "书架读取失败：\(error.localizedDescription)"
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard loaded, !importing else { return }
        importing = true
        defer { importing = false }
        var failures: [String] = []
        for url in urls {
            do {
                let directory = root
                let book = try await Task.detached(priority: .userInitiated) {
                    try ComicImport.run(url: url, root: directory)
                }.value
                if let index = books.firstIndex(where: { $0.id == book.id }) {
                    var existing = books[index]
                    existing.modifiedAt = Date()
                    books[index] = existing
                } else { books.insert(book, at: 0) }
                deleted.removeValue(forKey: book.id)
                save()
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func directory(for book: ComicBook) -> URL {
        let base = root.appendingPathComponent(book.id)
        guard let chapter = book.origin?.chapterURL else { return base }
        return base.appendingPathComponent("chapters").appendingPathComponent(Self.hash(chapter))
    }

    func chapterDirectory(bookID: String, chapterURL: String) -> URL {
        root.appendingPathComponent(bookID).appendingPathComponent("chapters").appendingPathComponent(Self.hash(chapterURL))
    }
    func isAvailable(_ book: ComicBook) -> Bool {
        if book.origin != nil && book.origin?.chapterURL == nil { return false }
        return FileManager.default.fileExists(atPath: directory(for: book).appendingPathComponent(book.format == .pdf ? "comic.pdf" : "000000").path)
            || (book.origin != nil && FileManager.default.fileExists(atPath: directory(for: book).appendingPathComponent("chapter.cbz").path))
    }
    func cover(for book: ComicBook) -> UIImage? {
        coverCache.object(forKey: book.id as NSString)
    }

    func loadCover(for book: ComicBook) async -> UIImage? {
        if let cached = cover(for: book) { return cached }
        let directory = root.appendingPathComponent(book.id)
        let revision = coverRevisions[book.id, default: 0]
        let task: Task<UIImage?, Never>
        if let pending = coverLoads[book.id], pending.revision == revision { task = pending.task }
        else {
            task = Task.detached(priority: .utility) { () -> UIImage? in
                for name in ["custom-cover.jpg", "source-cover.jpg", "cover.jpg"] {
                    if let image = UIImage(contentsOfFile: directory.appendingPathComponent(name).path) {
                        return image.preparingThumbnail(of: CGSize(width: 360, height: 540)) ?? image.preparingForDisplay() ?? image
                    }
                }
                return nil
            }
            coverLoads[book.id] = (revision, task)
        }
        let image = await task.value
        if coverLoads[book.id]?.revision == revision { coverLoads[book.id] = nil }
        guard revision == coverRevisions[book.id, default: 0] else { return await loadCover(for: book) }
        if let image { coverCache.setObject(image, forKey: book.id as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)) }
        return image
    }

    private func invalidateCover(_ id: String) {
        coverCache.removeObject(forKey: id as NSString)
        coverRevisions[id, default: 0] += 1
    }

    func refreshDownloadedChapters(bookIDs: Set<String>) async {
        let directory = root
        let revisions = downloadRevisions
        let values = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: bookIDs.map { id in
                let folders = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(id).appendingPathComponent("chapters"), includingPropertiesForKeys: nil)) ?? []
                let urls = folders.compactMap { folder -> String? in
                    guard let data = try? Data(contentsOf: folder.appendingPathComponent("chapter.json")),
                          let chapter = try? JSONDecoder().decode(CachedChapter.self, from: data) else { return nil }
                    return chapter.chapter.url
                }
                return (id, Set(urls))
            })
        }.value
        guard !Task.isCancelled else { return }
        var updated = downloadedChapters
        for (id, urls) in values where revisions[id] == downloadRevisions[id] { updated[id] = urls }
        if updated != downloadedChapters { downloadedChapters = updated }
    }

    func isChapterDownloaded(bookID: String, chapterURL: String) -> Bool {
        downloadedChapters[bookID]?.contains(chapterURL) == true
    }

    func shelfMetrics(downloaded: [String: Set<String>]? = nil) -> [String: ShelfBookMetrics] {
        let downloaded = downloaded ?? downloadedChapters
        return Dictionary(uniqueKeysWithValues: books.filter { $0.inLibrary != false }.map { book in
            let count = book.mangaInfo?.chapterCount ?? (book.origin == nil ? 1 : book.chapters?.count ?? 0)
            let read = (book.chapters ?? []).filter(\.completed).count
            return (book.id, ShelfBookMetrics(chapters: count, unread: max(0, count - read),
                downloaded: book.origin == nil && isAvailable(book) ? 1 : downloaded[book.id]?.count ?? 0, latest: book.mangaInfo?.latestUpload ?? 0))
        })
    }

    func downloadedChapterChanged(bookID: String, chapterURL: String, available: Bool) {
        downloadRevisions[bookID, default: 0] += 1
        var chapters = downloadedChapters[bookID] ?? []
        if available { chapters.insert(chapterURL) } else { chapters.remove(chapterURL) }
        downloadedChapters[bookID] = chapters
    }

    func cacheSourceCover(_ book: ComicBook, source: MangaSource, refresh: Bool = false) async {
        guard let origin = book.origin, let url = origin.thumbnail, !url.isEmpty else { return }
        let directory = root.appendingPathComponent(book.id)
        let marker = directory.appendingPathComponent("cover-source-url.txt")
        let target = directory.appendingPathComponent("source-cover.jpg")
        if !refresh, await Task.detached(priority: .utility, operation: {
            (try? String(contentsOf: marker, encoding: .utf8)) == url && UIImage(contentsOfFile: target.path) != nil
        }).value { return }
        do {
            let image = try await SourceCoverCache.load(source: source, url: url, refresh: refresh)
            guard books.contains(where: { $0.id == book.id }),
                  let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 360, height: 540)) else { return }
            try await Task.detached(priority: .utility) {
                guard let data = thumbnail.jpegData(compressionQuality: 0.85) else { throw ComicImport.ImportError.invalidImage }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                try url.write(to: marker, atomically: true, encoding: .utf8)
            }.value
            invalidateCover(book.id)
        } catch {
            if refresh { errorMessage = "封面加载失败：" + error.localizedDescription }
        }
    }

    nonisolated static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    func addOnline(_ manga: SourceManga, source: MangaSource, favorite: Bool = true) -> ComicBook {
        let id = Self.hash(source.id + "\n" + manga.url)
        if let index = books.firstIndex(where: { $0.id == id }) {
            if favorite, books[index].inLibrary == false {
                books[index].inLibrary = true; books[index].modifiedAt = Date(); save()
            }
            return books[index]
        }
        var book = ComicBook(id: id, title: manga.title, format: .images, pageCount: 1, importedAt: Date())
        book.origin = ComicOrigin(sourceID: source.id, mangaURL: manga.url, thumbnail: manga.thumbnail, mangaMemo: manga.memo)
        book.inLibrary = favorite
        let category = UserDefaults.standard.string(forKey: "library.defaultCategory") ?? ""
        if favorite, !category.isEmpty, category != "ask" { book.categories = [category] }
        books.insert(book, at: 0); deleted.removeValue(forKey: id); save()
        return book
    }

    func setFavorite(_ favorite: Bool, bookID: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        if favorite, books[index].inLibrary == false, (books[index].categories ?? []).isEmpty {
            let category = UserDefaults.standard.string(forKey: "library.defaultCategory") ?? ""
            if !category.isEmpty, category != "ask" { books[index].categories = [category] }
        }
        books[index].inLibrary = favorite; books[index].modifiedAt = Date(); save()
    }

    func cachedDetails(for book: ComicBook) -> SourceDetails? {
        if let details = detailsCache[book.id] { return details }
        let directory = root.appendingPathComponent(book.id)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("manga.json")),
           let details = try? JSONDecoder().decode(SourceDetails.self, from: data) { detailsCache[book.id] = details; return details }
        guard let origin = book.origin else { return nil }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("chapters"),
                                                                   includingPropertiesForKeys: nil)) ?? []
        var chapters = folders.compactMap { folder -> SourceChapter? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("chapter.json")) else { return nil }
            return (try? JSONDecoder().decode(CachedChapter.self, from: data))?.chapter
        }
        let known = Set(chapters.map(\.url))
        chapters += (book.chapters ?? []).filter { !known.contains($0.url) }.map {
            SourceChapter(url: $0.url, name: $0.title, number: -1, uploaded: 0,
                          memo: $0.url == origin.chapterURL ? origin.chapterMemo : nil)
        }
        if let url = origin.chapterURL, !chapters.contains(where: { $0.url == url }) {
            chapters.append(SourceChapter(url: url, name: origin.chapterTitle ?? "章节", number: -1,
                                          uploaded: 0, memo: origin.chapterMemo))
        }
        guard !chapters.isEmpty else { return nil }
        chapters.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        return SourceDetails(manga: SourceManga(url: origin.mangaURL, title: book.title,
                                               thumbnail: origin.thumbnail, memo: origin.mangaMemo),
                             chapters: chapters)
    }

    func cacheImportedDetails(_ details: SourceDetails, bookID: String) throws {
        let directory = root.appendingPathComponent(bookID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(details).write(to: directory.appendingPathComponent("manga.json"), options: .atomic)
        detailsCache[bookID] = details
    }

    func saveDetails(_ details: SourceDetails, source: MangaSource) {
        let id = Self.hash(source.id + "\n" + details.manga.url)
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        do {
            let directory = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(details).write(to: directory.appendingPathComponent("manga.json"), options: .atomic)
            detailsCache[id] = details
            var origin = books[index].origin
            books[index].mangaInfo = MangaMetadata(author: details.manga.author, artist: details.manga.artist,
                genre: details.manga.genre, status: details.manga.status, chapterCount: details.chapters.count,
                latestUpload: details.chapters.map(\.uploaded).max() ?? 0, fetchedAt: Date())
            if let thumbnail = details.manga.thumbnail, !thumbnail.isEmpty { origin?.thumbnail = thumbnail }
            if let memo = details.manga.memo { origin?.mangaMemo = memo }
            books[index].origin = origin; books[index].modifiedAt = Date(); save()
        } catch { errorMessage = "漫画详情保存失败：" + error.localizedDescription }
    }

    func openChapter(_ chapter: SourceChapter, pages: Int, bookID: String) -> ComicBook? {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return nil }
        let previous = books[index].chapters?.first { $0.url == chapter.url }
        if books[index].origin?.chapterURL != chapter.url || previous?.completed == true {
            books[index].lastPage = previous?.completed == true ? 0 : min(previous?.lastPage ?? 0, max(0, pages - 1))
            books[index].progressRevision = UUID().uuidString
        }
        books[index].origin?.chapterURL = chapter.url
        books[index].origin?.chapterTitle = chapter.name
        books[index].origin?.chapterMemo = chapter.memo
        books[index].pageCount = pages
        if books[index].lastPage >= pages { books[index].lastPage = max(0, pages - 1); books[index].progressRevision = UUID().uuidString }
        books[index].lastRead = Date(); books[index].historyModifiedAt = Date(); books[index].modifiedAt = Date(); recordChapter(index, finished: false); save()
        return books[index]
    }

    func setPage(_ page: Int, for id: String, finished: Bool? = nil) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let completionChanged = finished == true && books[index].chapters?.first(where: { $0.url == books[index].origin?.chapterURL })?.completed != true
        guard books[index].lastPage != page || books[index].lastRead == nil || completionChanged else { return }
        books[index].lastPage = min(max(page, 0), books[index].pageCount - 1)
        books[index].lastRead = Date()
        books[index].historyModifiedAt = Date()
        books[index].modifiedAt = Date()
        books[index].progressRevision = UUID().uuidString
        recordChapter(index, finished: finished)
        save(deferred: true)
    }

    private func recordChapter(_ index: Int, finished: Bool? = nil) {
        guard let origin = books[index].origin, let url = origin.chapterURL else { return }
        var chapters = books[index].chapters ?? []
        let old = chapters.first { $0.url == url }
        chapters.removeAll { $0.url == url }
        chapters.append(ChapterProgress(url: url, title: origin.chapterTitle ?? "章节", pageCount: books[index].pageCount, lastPage: books[index].lastPage,
            completed: old?.completed == true || (finished ?? (books[index].lastPage == books[index].pageCount - 1)), lastRead: books[index].lastRead,
            bookmarked: old?.bookmarked, bookmarkModifiedAt: old?.bookmarkModifiedAt, historyModifiedAt: books[index].historyModifiedAt))
        books[index].chapters = chapters
    }

    func markChapters(_ chapters: [SourceChapter], bookID: String, completed: Bool) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        var progress = books[index].chapters ?? []
        for chapter in chapters {
            let old = progress.first { $0.url == chapter.url }
            progress.removeAll { $0.url == chapter.url }
            let count = old?.pageCount ?? 1
            progress.append(ChapterProgress(url: chapter.url, title: chapter.name, pageCount: count, lastPage: completed ? count - 1 : 0, completed: completed, lastRead: old?.lastRead, bookmarked: old?.bookmarked, bookmarkModifiedAt: old?.bookmarkModifiedAt, historyModifiedAt: old?.historyModifiedAt))
            if books[index].origin?.chapterURL == chapter.url {
                books[index].lastPage = completed ? books[index].pageCount - 1 : 0
                books[index].progressRevision = UUID().uuidString
            }
        }
        books[index].chapters = progress; books[index].modifiedAt = Date(); save()
    }

    func bookmarkChapter(_ chapter: SourceChapter, bookID: String) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        var chapters = books[index].chapters ?? []
        if let row = chapters.firstIndex(where: { $0.url == chapter.url }) {
            chapters[row].bookmarked = !(chapters[row].bookmarked ?? false)
            chapters[row].modifiedAt = Date()
            chapters[row].bookmarkModifiedAt = Date()
        } else {
            chapters.append(ChapterProgress(url: chapter.url, title: chapter.name, pageCount: 1,
                                            lastPage: 0, completed: false, bookmarked: true, bookmarkModifiedAt: Date()))
        }
        books[index].chapters = chapters; books[index].modifiedAt = Date(); save()
    }

    func changeCover(_ bookID: String, input: URL) {
        let access = input.startAccessingSecurityScopedResource()
        defer { if access { input.stopAccessingSecurityScopedResource() } }
        guard let image = UIImage(contentsOfFile: input.path) else { errorMessage = ComicImport.ImportError.invalidImage.localizedDescription; return }
        changeCover(bookID, image: image)
    }

    func changeCover(_ bookID: String, image: UIImage) {
        do {
            guard let image = image.preparingThumbnail(of: CGSize(width: 360, height: 540)), let data = image.jpegData(compressionQuality: 0.85) else { throw ComicImport.ImportError.invalidImage }
            let directory = root.appendingPathComponent(bookID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("custom-cover.jpg"), options: .atomic)
            invalidateCover(bookID)
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ id: String, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].title = title
        books[index].modifiedAt = Date()
        save()
    }

    func remove(_ book: ComicBook) {
        do {
            let base = root.appendingPathComponent(book.id)
            if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
            books.removeAll { $0.id == book.id }
            detailsCache[book.id] = nil; downloadedChapters[book.id] = nil
            downloadRevisions[book.id, default: 0] += 1
            invalidateCover(book.id)
            deleted[book.id] = Date()
            save()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleBookmark(_ page: Int, for id: String) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        let chapter = books[index].origin?.chapterURL
        if let mark = books[index].bookmarks.firstIndex(where: { $0.page == page && $0.chapterURL == chapter && !$0.deleted }) {
            books[index].bookmarks[mark].deleted = true
            books[index].bookmarks[mark].modifiedAt = Date()
        } else {
            var mark = ComicBookmark(page: page, title: [books[index].origin?.chapterTitle, "第 \(page + 1) 页"].compactMap { $0 }.joined(separator: " · "))
            mark.chapterURL = chapter; mark.pageCount = books[index].pageCount
            books[index].bookmarks.append(mark)
        }
        books[index].modifiedAt = Date()
        save()
    }

    var categoryNames: [String] {
        var names = categories.filter { !$0.deleted }.sorted { $0.order < $1.order }.map(\.name)
        var unique = Set<String>(); names = names.filter { unique.insert($0).inserted }
        for name in books.flatMap({ $0.categories ?? [] }).sorted() where !names.contains(name) { names.append(name) }
        return names
    }

    func addCategory(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !categoryNames.contains(name) else { return }
        categories.append(ShelfCategory(name: name, order: categoryNames.count)); save()
    }

    func renameCategory(_ old: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, old != name, !categoryNames.contains(name) else { return }
        if let i = categories.firstIndex(where: { $0.name == old && !$0.deleted }) {
            categories[i].name = name; categories[i].modifiedAt = Date()
        } else { categories.append(ShelfCategory(name: name, order: categoryNames.count)) }
        for i in books.indices where books[i].categories?.contains(old) == true {
            books[i].categories = books[i].categories?.map { $0 == old ? name : $0 }; books[i].modifiedAt = Date()
        }
        if UserDefaults.standard.string(forKey: "library.defaultCategory") == old { UserDefaults.standard.set(name, forKey: "library.defaultCategory") }
        save()
    }

    func deleteCategory(_ name: String) {
        for i in categories.indices where categories[i].name == name { categories[i].deleted = true; categories[i].modifiedAt = Date() }
        for i in books.indices where books[i].categories?.contains(name) == true {
            books[i].categories?.removeAll { $0 == name }; books[i].modifiedAt = Date()
        }
        if UserDefaults.standard.string(forKey: "library.defaultCategory") == name { UserDefaults.standard.removeObject(forKey: "library.defaultCategory") }
        save()
    }

    func reorderCategories(_ names: [String]) {
        for (order, name) in names.enumerated() {
            if let i = categories.firstIndex(where: { $0.name == name && !$0.deleted }) {
                categories[i].order = order; categories[i].modifiedAt = Date()
            } else { categories.append(ShelfCategory(name: name, order: order)) }
        }
        save()
    }

    func setCategories(_ names: [String], bookIDs: Set<String>) {
        for i in books.indices where bookIDs.contains(books[i].id) { books[i].categories = names; books[i].modifiedAt = Date() }
        save()
    }

    func setReaderSettings(_ settings: MangaReaderSettings, bookID: String) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].readerSettings = settings; books[i].modifiedAt = Date(); save()
    }

    func applyMigration(from original: ComicBook, to bookID: String, matches: [String: String], chapters: [SourceChapter], removeOriginal: Bool) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        var progress = books[i].chapters ?? []
        for old in original.chapters ?? [] {
            guard let url = matches[old.url], let chapter = chapters.first(where: { $0.url == url }) else { continue }
            let previous = progress.first { $0.url == url }
            if previous?.completed == true && !old.completed { continue }
            progress.removeAll { $0.url == url }
            progress.append(ChapterProgress(url: url, title: chapter.name, pageCount: old.pageCount, lastPage: old.lastPage,
                completed: old.completed, lastRead: old.lastRead, bookmarked: old.bookmarked == true || previous?.bookmarked == true, bookmarkModifiedAt: Date()))
        }
        books[i].chapters = progress
        books[i].categories = Array(Set((books[i].categories ?? []) + (original.categories ?? []))).sorted()
        books[i].readerSettings = original.readerSettings
        for mark in original.bookmarks where !mark.deleted {
            guard let oldURL = mark.chapterURL, let url = matches[oldURL] else { continue }
            var copied = mark; copied.id = Self.hash(bookID + "\n" + mark.id); copied.chapterURL = url; copied.modifiedAt = Date()
            books[i].bookmarks.removeAll { $0.id == copied.id }; books[i].bookmarks.append(copied)
        }
        if let oldURL = original.origin?.chapterURL, let url = matches[oldURL], let chapter = chapters.first(where: { $0.url == url }) {
            books[i].origin?.chapterURL = url; books[i].origin?.chapterTitle = chapter.name; books[i].origin?.chapterMemo = chapter.memo
            books[i].pageCount = original.pageCount; books[i].lastPage = original.lastPage; books[i].lastRead = original.lastRead
            books[i].progressRevision = UUID().uuidString
        }
        books[i].modifiedAt = Date()
        if removeOriginal, let old = books.firstIndex(where: { $0.id == original.id }), old != i { books[old].inLibrary = false; books[old].modifiedAt = Date() }
        save()
    }

    func clearHistory(bookID: String? = nil, chapterURL: String? = nil) {
        for i in books.indices where bookID == nil || books[i].id == bookID {
            if chapterURL == nil {
                books[i].lastRead = nil
                for j in (books[i].chapters ?? []).indices { books[i].chapters?[j].lastRead = nil; books[i].chapters?[j].historyModifiedAt = Date() }
            } else {
                for j in (books[i].chapters ?? []).indices where books[i].chapters?[j].url == chapterURL { books[i].chapters?[j].lastRead = nil; books[i].chapters?[j].historyModifiedAt = Date() }
                books[i].lastRead = books[i].chapters?.compactMap(\.lastRead).max()
            }
            books[i].modifiedAt = Date()
            books[i].historyModifiedAt = Date()
        }
        save()
    }

    func snapshot() -> ShelfState { ShelfState(books: books, deleted: deleted, categories: categories.isEmpty ? nil : categories) }

    func acceptSync(_ remote: ShelfState, captured: ShelfState) {
        let previous = snapshot()
        var incomingCategories = Dictionary(uniqueKeysWithValues: (remote.categories ?? []).map { ($0.id, $0) })
        let capturedCategories = Dictionary(uniqueKeysWithValues: (captured.categories ?? []).map { ($0.id, $0) })
        for category in categories where category != capturedCategories[category.id] { incomingCategories[category.id] = category }
        categories = incomingCategories.values.sorted { $0.order < $1.order }
        // Preserve any local edits made while the network request was in flight.
        let capturedBooks = Dictionary(uniqueKeysWithValues: captured.books.map { ($0.id, $0) })
        var merged = Dictionary(uniqueKeysWithValues: remote.books.map { ($0.id, $0) })
        for book in books where book != capturedBooks[book.id] { merged[book.id] = book }
        for (id, date) in remote.deleted { deleted[id] = max(deleted[id] ?? .distantPast, date) }
        books = merged.values.filter { (deleted[$0.id] ?? .distantPast) < $0.modifiedAt }
            .sorted { $0.importedAt > $1.importedAt }
        if snapshot() != previous { save() }
    }

    private func save(deferred: Bool = false) {
        guard loaded else { return }
        changeCount += 1
        pendingSave?.cancel(); pendingSave = nil
        if deferred {
            pendingSave = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard let self else { return }
                self.pendingSave = nil; self.writeSnapshot()
            }
        } else { writeSnapshot() }
    }

    private func writeSnapshot() {
        #if DEBUG
        storageWrites += 1
        #endif
        writer.write(snapshot()) { [weak self] error in
            if let error { self?.errorMessage = "书架保存失败：" + error }
        }
    }

    func flushPendingSaves() async throws {
        if pendingSave != nil { pendingSave?.cancel(); pendingSave = nil; writeSnapshot() }
        try await writer.flush()
    }
}
