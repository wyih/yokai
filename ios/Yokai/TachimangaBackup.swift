import Foundation
import CoreFoundation
import SQLite3
import ZIPFoundation

enum TachimangaBackup {
    static func read(_ url: URL) throws -> NativeShelfBackup {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outer = try Archive(url: url, accessMode: .read)
        guard outer["meta.json"] != nil else { throw invalid("缺少备份信息") }
        let contents = folder.appendingPathComponent("contents.zip")
        try extract("contents.zip", from: outer, to: contents, limit: 256 * 1024 * 1024)
        let archive = try Archive(url: contents, accessMode: .read)
        let database = folder.appendingPathComponent("tachimanga.db")
        try extract("tachimanga.db", from: archive, to: database, limit: 256 * 1024 * 1024)
        let db = try Database(database)
        let histories = try db.rows("History", optional: true).filter { !$0.flag("is_delete") }
        let history = Dictionary(grouping: histories, by: { $0.text("manga_id") })
            .mapValues { $0.max { $0.integer("last_read_at") < $1.integer("last_read_at") }! }
        let rawChapters = try db.rows("Chapter")
        var chapters = Dictionary(grouping: rawChapters, by: { $0.text("manga") })
        for sync in try db.rows("ChapterSync", optional: true) {
            let id = sync.text("manga_id"), url = sync.text("url")
            if let index = chapters[id]?.firstIndex(where: { $0.text("url") == url }) {
                let old = chapters[id]![index]
                if sync.integer("last_read_at") >= old.integer("last_read_at") {
                    var merged = old
                    for key in ["read", "bookmark", "last_page_read", "last_read_at"] { merged.values[key] = sync.values[key] ?? old.values[key] }
                    chapters[id]![index] = merged
                }
            } else { chapters[id, default: []].append(sync) }
        }
        let categories = try db.rows("Category", optional: true).filter { !$0.flag("is_delete") }
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.text("id"), $0.text("name")) })
        let memberships = Dictionary(grouping: try db.rows("CategoryManga", optional: true), by: { $0.text("manga") })
        let metadata = Dictionary(grouping: try db.rows("MangaMeta", optional: true), by: { $0.text("manga_ref") })
        var books: [ComicBook] = [], details: [String: SourceDetails] = [:]
        for manga in try db.rows("Manga") {
            let key = manga.text("id"), rows = (chapters[key] ?? []).sorted { $0.integer("source_order") < $1.integer("source_order") }
            guard manga.flag("in_library") || history[key] != nil || rows.contains(where: { $0.flag("read") || $0.flag("bookmark") || $0.integer("last_read_at") > 0 }) else { continue }
            let source = manga.text("source"), url = manga.text("url")
            guard Int64(source) != nil, !url.isEmpty else { throw invalid("漫画图源或地址无效") }
            let id = ComicLibrary.hash(source + "\n" + url)
            let selected = history[key].flatMap { h in rows.first { $0.text("id") == h.text("last_chapter_id") } }
                ?? rows.filter { $0.integer("last_read_at") > 0 }.max { $0.integer("last_read_at") < $1.integer("last_read_at") }
            var book = ComicBook(id: id, title: manga.text("title"), format: .images, pageCount: 1,
                importedAt: date(manga.integer("in_library_at")) ?? date(manga.integer("create_at")) ?? Date())
            book.origin = ComicOrigin(sourceID: source, mangaURL: url, thumbnail: manga.values["thumbnail_url"], mangaMemo: memo(manga.text("memo")))
            book.inLibrary = manga.flag("in_library")
            book.categories = memberships[key]?.compactMap { categoryNames[$0.text("category")] } ?? []
            book.chapters = try rows.map { chapter in
                let lastPage = max(0, chapter.integer("last_page_read"))
                guard lastPage < Int64(Int.max) else { throw invalid("章节进度无效") }
                let count = max(lastPage + 1, chapter.integer("page_count"))
                let readAt = max(chapter.integer("last_read_at"), chapter.text("id") == selected?.text("id") ? history[key]?.integer("last_read_at") ?? 0 : 0)
                return ChapterProgress(url: chapter.text("url"), title: chapter.text("name"), pageCount: Int(count), lastPage: Int(lastPage),
                    completed: chapter.flag("read"), lastRead: date(readAt), bookmarked: chapter.flag("bookmark"),
                    bookmarkModifiedAt: chapter.flag("bookmark") ? Date() : nil, historyModifiedAt: readAt > 0 ? Date() : nil)
            }
            if let selected, let progress = book.chapters?.first(where: { $0.url == selected.text("url") }) {
                book.origin?.chapterURL = progress.url; book.origin?.chapterTitle = progress.title; book.origin?.chapterMemo = memo(selected.text("memo"))
                book.pageCount = progress.pageCount; book.lastPage = progress.lastPage; book.lastRead = progress.lastRead
            } else { book.lastRead = history[key].flatMap { date($0.integer("last_read_at")) } }
            book.historyModifiedAt = book.lastRead != nil ? Date() : nil
            if let mode = metadata[key]?.first(where: { $0.text("key") == "flutter_readerMode" })?.text("value"),
               ["ltr", "rtl", "webtoon", "vertical"].contains(mode) { book.readerSettings = MangaReaderSettings(mode: mode) }
            let sourceChapters = rows.map { SourceChapter(url: $0.text("url"), name: $0.text("name"), number: $0.decimal("chapter_number", fallback: -1), uploaded: milliseconds($0.integer("date_upload")), memo: memo($0.text("memo"))) }
            let info = SourceManga(url: url, title: book.title, thumbnail: book.origin?.thumbnail, author: manga.values["author"], artist: manga.values["artist"],
                description: manga.values["description"], genre: manga.values["genre"], status: Int(manga.integer("status")), memo: book.origin?.mangaMemo)
            book.mangaInfo = MangaMetadata(author: info.author, artist: info.artist, genre: info.genre, status: info.status, chapterCount: rows.count,
                latestUpload: sourceChapters.map(\.uploaded).max() ?? 0, fetchedAt: date(manga.integer("last_fetched_at")) ?? Date())
            details[id] = SourceDetails(manga: info, chapters: sourceChapters)
            books.append(book)
        }
        guard !books.isEmpty || !categories.isEmpty else { throw invalid("没有可恢复的书架或阅读记录") }
        let shelf = ShelfState(books: books, categories: categories.map { ShelfCategory(id: "android-" + ComicLibrary.hash($0.text("name")), name: $0.text("name"), order: Int($0.integer("order"))) })
        try ShelfMerge.validate(shelf)
        var backup = NativeShelfBackup(shelf: shelf)
        backup.details = details
        backup.sourcePreferences = try archive.filter { $0.path.hasPrefix("prefs/suwayomi.tachidesk.source_") && $0.path.hasSuffix(".plist") }.map { entry in
            let raw = try data(entry.path, from: archive)
            guard let plist = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any],
                  let values = plist.values.first as? [String: Any] else { throw invalid("图源设置格式无效") }
            let name = URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "suwayomi.tachidesk.", with: "")
            guard name.hasPrefix("source_"), Int64(name.dropFirst(7)) != nil else { throw invalid("图源设置标识无效") }
            return AndroidSourcePreferences(name: name, preferences: try values.map { key, value in
                if let number = value as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() { return AndroidPreference(key: key, type: "boolean", value: .boolean(number.boolValue)) }
                    return AndroidPreference(key: key, type: "long", value: .integer(number.int64Value))
                }
                if let value = value as? String { return AndroidPreference(key: key, type: "string", value: .string(value)) }
                if let value = value as? [String] { return AndroidPreference(key: key, type: "set", value: .strings(value)) }
                throw invalid("图源设置值无效")
            })
        }
        if archive["pref.json"] != nil {
            let raw = try data("pref.json", from: archive)
            guard let values = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw invalid("应用设置格式无效") }
            var preferences: [String: Any] = [:]
            if let keepAwake = values["flutter.keepScreenOnWhileReading"] as? Bool { preferences["reader.keepAwake"] = keepAwake }
            if let showStatusBar = values["flutter.showStatusBar"] as? Bool { preferences["reader.fullscreen"] = !showStatusBar }
            backup.preferences = try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
        }
        return backup
    }

    private static func extract(_ name: String, from archive: Archive, to url: URL, limit: UInt64) throws {
        guard let entry = archive[name], entry.type == .file, UInt64(entry.uncompressedSize) <= limit else { throw invalid("缺少 \(name)，或文件过大") }
        _ = try archive.extract(entry, to: url)
    }
    private static func data(_ name: String, from archive: Archive) throws -> Data {
        guard let entry = archive[name], entry.type == .file, entry.uncompressedSize <= 4 * 1024 * 1024 else { throw invalid("设置文件无效或过大") }
        var result = Data()
        _ = try archive.extract(entry) { result.append($0) }
        return result
    }
    private static func date(_ value: Int64) -> Date? { value > 0 ? Date(timeIntervalSince1970: Double(value) / (value >= 100_000_000_000 ? 1000 : 1)) : nil }
    private static func milliseconds(_ value: Int64) -> Int64 { value > 0 && value < 100_000_000_000 ? value * 1000 : max(0, value) }
    private static func memo(_ value: String) -> String { (try? JSONSerialization.jsonObject(with: Data(value.utf8))) is [String: Any] ? value : "{}" }
    private static func invalid(_ reason: String) -> SourceError { .message("无法读取 Tachimanga 备份：\(reason)。") }

    private struct Row {
        var values: [String: String]
        func text(_ key: String) -> String { values[key] ?? "" }
        func integer(_ key: String) -> Int64 { Int64(text(key)) ?? 0 }
        func decimal(_ key: String, fallback: Double) -> Double { Double(text(key)).flatMap { $0.isFinite ? $0 : nil } ?? fallback }
        func flag(_ key: String) -> Bool { integer(key) != 0 }
    }
    private final class Database {
        private var handle: OpaquePointer?
        init(_ url: URL) throws {
            guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(handle); handle = nil; throw invalid("数据库无法打开")
            }
        }
        deinit { sqlite3_close(handle) }
        func rows(_ table: String, optional: Bool = false) throws -> [Row] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            if optional {
                var lookup: OpaquePointer?
                defer { sqlite3_finalize(lookup) }
                guard sqlite3_prepare_v2(handle, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &lookup, nil) == SQLITE_OK else { throw invalid("数据库结构无效") }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(lookup, 1, table, -1, transient)
                if sqlite3_step(lookup) == SQLITE_DONE { return [] }
            }
            guard sqlite3_prepare_v2(handle, "SELECT * FROM \"\(table)\"", -1, &statement, nil) == SQLITE_OK else { throw invalid("缺少 \(table) 数据") }
            var result: [Row] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                var values: [String: String] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    if let raw = sqlite3_column_text(statement, index) { values[String(cString: sqlite3_column_name(statement, index))] = String(cString: raw) }
                }
                result.append(Row(values: values)); status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw invalid("数据库内容损坏") }
            return result
        }
    }
}
