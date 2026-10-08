import Foundation

struct ComicBookmark: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    let page: Int
    var title: String
    var modifiedAt = Date()
    var deleted = false
    var chapterURL: String?
    var pageCount: Int?
}

struct ComicOrigin: Codable, Equatable, Sendable {
    let sourceID: String
    let mangaURL: String
    var thumbnail: String?
    var mangaMemo: String?
    var chapterURL: String?
    var chapterTitle: String?
    var chapterMemo: String?
}

struct ChapterProgress: Codable, Identifiable, Equatable, Sendable {
    var id: String { url }
    let url: String
    var title: String
    var pageCount: Int
    var lastPage: Int
    var completed: Bool
    var modifiedAt = Date()
    var lastRead: Date?
    var bookmarked: Bool?
    var bookmarkModifiedAt: Date?
    var historyModifiedAt: Date?
}

struct ComicBook: Codable, Identifiable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case images, pdf }
    let id: String
    var title: String
    let format: Format
    var pageCount: Int
    var lastPage = 0
    var lastRead: Date?
    let importedAt: Date
    var modifiedAt = Date()
    var progressRevision = UUID().uuidString
    var bookmarks: [ComicBookmark] = []
    var origin: ComicOrigin?
    var chapters: [ChapterProgress]?
    var categories: [String]?
    var inLibrary: Bool?
    var readerSettings: MangaReaderSettings?
    var mangaInfo: MangaMetadata?
    // Original protobuf fields not interpreted by iOS (e.g. tracker records).
    var androidBackupData: String?
    var historyModifiedAt: Date?
}

struct MangaMetadata: Codable, Equatable, Sendable {
    var author: String?
    var artist: String?
    var genre: String?
    var status: Int?
    var chapterCount: Int
    var latestUpload: Int64
    var fetchedAt: Date
}

struct MangaReaderSettings: Codable, Equatable, Sendable {
    var mode: String?
    var orientation: String?
    var trimBorders: Bool?
    var doublePage: Bool?
    var scale: String?
    var layout: String?
}

struct ShelfCategory: Codable, Identifiable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var order: Int
    var modifiedAt = Date()
    var deleted = false
}

struct ShelfState: Codable, Equatable, Sendable {
    var schema = 2
    var books: [ComicBook] = []
    var deleted: [String: Date] = [:]
    var categories: [ShelfCategory]?
}

struct ProgressConflict: Identifiable {
    var id: String { local.id }
    let local: ComicBook
    let remote: ComicBook
}

struct ProgressChoice {
    let localRevision: String
    let remoteRevision: String
    let keepLocal: Bool

    init(conflict: ProgressConflict, keepLocal: Bool) {
        localRevision = conflict.local.progressRevision
        remoteRevision = conflict.remote.progressRevision
        self.keepLocal = keepLocal
    }

    func matches(local: ComicBook, remote: ComicBook) -> Bool {
        localRevision == local.progressRevision && remoteRevision == remote.progressRevision
    }
}

struct ShelfMergeResult {
    let state: ShelfState
    let conflicts: [ProgressConflict]
}

enum ShelfMerge {
    static func merge(local: ShelfState, remote: ShelfState, baseline: [String: String],
                      choices: [String: ProgressChoice] = [:]) -> ShelfMergeResult {
        var deleted = local.deleted
        for (id, date) in remote.deleted { deleted[id] = max(deleted[id] ?? .distantPast, date) }
        var books = Dictionary(uniqueKeysWithValues: remote.books.map { ($0.id, $0) })
        var conflicts: [ProgressConflict] = []
        for book in local.books {
            guard let other = books[book.id] else { books[book.id] = book; continue }
            var merged = book.modifiedAt >= other.modifiedAt ? book : other
            let localChanged = (book.lastRead != nil || book.historyModifiedAt != nil) && book.progressRevision != baseline[book.id]
            let remoteChanged = (other.lastRead != nil || other.historyModifiedAt != nil) && other.progressRevision != baseline[book.id]
            let divergent = localChanged && remoteChanged && book.progressRevision != other.progressRevision
                && (book.lastPage != other.lastPage || book.origin?.chapterURL != other.origin?.chapterURL)
            let choice = choices[book.id].flatMap { $0.matches(local: book, remote: other) ? $0 : nil }
            if divergent && choice == nil { conflicts.append(ProgressConflict(local: book, remote: other)) }
            let progress = choice.map { $0.keepLocal ? book : other } ?? (localChanged ? book : other)
            merged.lastPage = progress.lastPage
            merged.lastRead = progress.lastRead
            let history = (book.historyModifiedAt ?? book.lastRead ?? .distantPast) >= (other.historyModifiedAt ?? other.lastRead ?? .distantPast) ? book : other
            merged.lastRead = history.lastRead
            merged.historyModifiedAt = history.historyModifiedAt
            merged.progressRevision = progress.progressRevision
            merged.pageCount = progress.pageCount
            if merged.origin != nil {
                merged.origin?.chapterURL = progress.origin?.chapterURL
                merged.origin?.chapterTitle = progress.origin?.chapterTitle
                merged.origin?.chapterMemo = progress.origin?.chapterMemo
            }
            var bookmarks = Dictionary(uniqueKeysWithValues: other.bookmarks.map { ($0.id, $0) })
            for mark in book.bookmarks {
                if mark.modifiedAt >= (bookmarks[mark.id]?.modifiedAt ?? .distantPast) { bookmarks[mark.id] = mark }
            }
            merged.bookmarks = bookmarks.values.sorted { $0.id < $1.id }
            var chapters = Dictionary(uniqueKeysWithValues: (other.chapters ?? []).map { ($0.id, $0) })
            for chapter in book.chapters ?? [] {
                if chapter.modifiedAt >= (chapters[chapter.id]?.modifiedAt ?? .distantPast) { chapters[chapter.id] = chapter }
            }
            if choice != nil, let url = progress.origin?.chapterURL,
               let selectedChapter = progress.chapters?.first(where: { $0.url == url }) {
                chapters[url] = selectedChapter
            }
            for candidate in (other.chapters ?? []) + (book.chapters ?? []) {
                guard let changed = candidate.bookmarkModifiedAt, var chapter = chapters[candidate.url],
                      changed >= (chapter.bookmarkModifiedAt ?? .distantPast) else { continue }
                chapter.bookmarked = candidate.bookmarked
                chapter.bookmarkModifiedAt = changed
                chapters[candidate.url] = chapter
            }
            for candidate in (other.chapters ?? []) + (book.chapters ?? []) {
                guard var chapter = chapters[candidate.url],
                      (candidate.historyModifiedAt ?? candidate.lastRead ?? .distantPast) >= (chapter.historyModifiedAt ?? chapter.lastRead ?? .distantPast) else { continue }
                chapter.lastRead = candidate.lastRead; chapter.historyModifiedAt = candidate.historyModifiedAt
                chapters[candidate.url] = chapter
            }
            merged.chapters = chapters.isEmpty ? nil : chapters.values.sorted { $0.id < $1.id }
            books[book.id] = merged
        }
        books = books.filter { id, book in (deleted[id] ?? .distantPast) < book.modifiedAt }
        var categories = Dictionary(uniqueKeysWithValues: (remote.categories ?? []).map { ($0.id, $0) })
        for category in local.categories ?? [] {
            if category.modifiedAt >= (categories[category.id]?.modifiedAt ?? .distantPast) { categories[category.id] = category }
        }
        return ShelfMergeResult(state: ShelfState(books: books.values.sorted { $0.id < $1.id }, deleted: deleted,
                                                 categories: categories.isEmpty ? nil : categories.values.sorted { $0.id < $1.id }),
                                conflicts: conflicts.filter { books[$0.id] != nil })
    }

    static func validate(_ state: ShelfState) throws {
        guard [1, 2].contains(state.schema),
              Set(state.books.map(\.id)).count == state.books.count else { throw SyncError.invalidData }
        for book in state.books {
            guard validID(book.id), book.pageCount > 0, (0..<book.pageCount).contains(book.lastPage),
                  !book.progressRevision.isEmpty,
                  Set(book.bookmarks.map(\.id)).count == book.bookmarks.count,
                  Set((book.chapters ?? []).map(\.id)).count == (book.chapters ?? []).count,
                  (book.chapters ?? []).allSatisfy({ $0.pageCount > 0 && (0..<$0.pageCount).contains($0.lastPage) }),
                  book.bookmarks.allSatisfy({ (0..<($0.pageCount ?? book.pageCount)).contains($0.page) }) else { throw SyncError.invalidData }
        }
        guard state.deleted.keys.allSatisfy(validID) else { throw SyncError.invalidData }
        let categories = state.categories ?? []
        guard Set(categories.map(\.id)).count == categories.count else { throw SyncError.invalidData }
    }

    private static func validID(_ id: String) -> Bool {
        id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

enum SyncError: LocalizedError {
    case invalidData, weakETag, conflict, server(Int), invalidURL, keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidData: "远端书架数据格式不兼容。"
        case .weakETag: "服务器未提供强 ETag，无法保护并发写入。"
        case .conflict: "其他设备正在更新书架，请稍后重试。"
        case .server(let code): "WebDAV 请求失败（HTTP \(code)），请检查地址、账户和权限。"
        case .invalidURL: "请填写 HTTPS 地址和相对个人目录。"
        case .keychain: "无法保存同步密码，请重试。"
        }
    }
}
