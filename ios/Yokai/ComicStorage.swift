import Foundation
import CryptoKit

struct ComicStorageFile: Sendable {
    let url: URL
    let bytes: Int64
    let modified: Date?
}

struct ComicStorageChapter: Sendable {
    let url: String
    let bytes: Int64
    let pages: Int
}

struct ComicStorageBook: Identifiable, Sendable {
    let id: String
    let title: String
    let imported: Bool
    var bytes: Int64 = 0
    var chapterBytes: Int64 = 0
    var chapters: [ComicStorageChapter] = []
}

struct ComicStorageInventory: Sendable {
    var books: [ComicStorageBook] = []
    var coverBytes: Int64 = 0
    var covers: [ComicStorageFile] = []
    var backupBytes: Int64 = 0
    var backups: [ComicStorageFile] = []
    var externalBackupBytes: Int64?
    var temporaryBytes: Int64 = 0
    var errors: [String] = []
    var total: Int64 { books.reduce(0) { $0 + $1.bytes } + coverBytes + backupBytes }
}

/// Only these owned directories are writable. The shared system temporary
/// directory and user-selected backup folder are measured, never swept.
enum ComicStorage {
    private struct ChapterMarker: Decodable {
        struct Chapter: Decodable { let url: String }
        let chapter: Chapter
        let pageCount: Int
    }

    static func scan(books: [ComicBook], root: URL, covers: URL, backups: URL,
                     externalBackups: URL?, temporary: URL,
                     progress: @Sendable (Int, String) -> Void) throws -> ComicStorageInventory {
        var result = ComicStorageInventory()
        for (index, book) in books.enumerated() {
            try Task.checkCancellation()
            var item = ComicStorageBook(id: book.id, title: book.title, imported: book.origin == nil)
            do {
                guard isDigest(book.id) else { throw StorageError.unsafePath }
                let folder = root.appendingPathComponent(book.id, isDirectory: true)
                item.bytes = try bytes(in: folder)
                if book.origin != nil {
                    let chapters = folder.appendingPathComponent("chapters", isDirectory: true)
                    item.chapterBytes = try bytes(in: chapters)
                    for directory in try children(of: chapters) {
                        try Task.checkCancellation()
                        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                        let marker = directory.appendingPathComponent("chapter.json")
                        guard FileManager.default.fileExists(atPath: marker.path) else { continue }
                        guard try isRegularFile(marker),
                              let chapter = try? JSONDecoder().decode(ChapterMarker.self, from: Data(contentsOf: marker)),
                              directory.lastPathComponent == digest(chapter.chapter.url) else {
                            throw StorageError.invalidChapter
                        }
                        item.chapters.append(ComicStorageChapter(url: chapter.chapter.url,
                            bytes: try bytes(in: directory), pages: max(0, chapter.pageCount)))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.errors.append(book.title + "：" + error.localizedDescription) }
            result.books.append(item)
            progress(index + 1, book.title)
        }
        result.books.sort { $0.bytes == $1.bytes ? $0.title < $1.title : $0.bytes > $1.bytes }
        do {
            result.coverBytes = try bytes(in: covers)
            // SourceCoverCache writes completed covers under SHA-256 keys.
            // Its UUID staging files may still be in use and are not removed.
            result.covers = try files(in: covers).filter { isDigest($0.url.lastPathComponent) }
        } catch is CancellationError { throw CancellationError() }
        catch { result.errors.append("封面缓存：" + error.localizedDescription) }
        progress(books.count + 1, "封面缓存")
        do {
            result.backups = try backupFiles(in: backups)
            result.backupBytes = result.backups.reduce(0) { $0 + $1.bytes }
            if let externalBackups, externalBackups.standardizedFileURL != backups.standardizedFileURL {
                result.externalBackupBytes = try backupFiles(in: externalBackups).reduce(0) { $0 + $1.bytes }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { result.errors.append("自动备份：" + error.localizedDescription) }
        do { result.temporaryBytes = try bytes(in: temporary) }
        catch is CancellationError { throw CancellationError() }
        catch { result.errors.append("临时文件：" + error.localizedDescription) }
        progress(books.count + 2, "备份与临时文件")
        return result
    }

    static func canRemove(chapterURL: String, book: ComicBook, unfinished: Set<String>,
                          excludedCategories: Set<String>, allowBookmarks: Bool) -> Bool {
        guard book.origin != nil, !unfinished.contains(chapterURL),
              Set(book.categories ?? []).isDisjoint(with: excludedCategories) else { return false }
        return allowBookmarks || (book.chapters?.first(where: { $0.url == chapterURL })?.bookmarked != true
            && !book.bookmarks.contains { !$0.deleted && $0.chapterURL == chapterURL })
    }

    static func validateChapter(root: URL, bookID: String, chapterURL: String) throws {
        guard isDigest(bookID) else { throw StorageError.unsafePath }
        let directory = root.appendingPathComponent(bookID).appendingPathComponent("chapters").appendingPathComponent(digest(chapterURL))
        try validatePath(directory)
    }

    /// Revalidate the inventory before deleting; newly written or changed files
    /// belong to work that may have started since the user reviewed the scan.
    static func remove(_ files: [ComicStorageFile], from root: URL) throws -> Int {
        try validatePath(root)
        var removed = 0
        for file in files {
            try Task.checkCancellation()
            var current = file.url
            current.removeAllCachedResourceValues()
            guard current.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { throw StorageError.unsafePath }
            guard FileManager.default.fileExists(atPath: current.path) else { continue }
            guard try isRegularFile(current) else { throw StorageError.unsafePath }
            let values = try current.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard Int64(values.fileSize ?? 0) == file.bytes, values.contentModificationDate == file.modified else { continue }
            try FileManager.default.removeItem(at: current)
            removed += 1
        }
        return removed
    }

    private static func backupFiles(in root: URL) throws -> [ComicStorageFile] {
        // This is the same format/ownership contract as AutomaticBackups.
        try files(in: root).filter { $0.url.lastPathComponent.hasPrefix("yokai_") && $0.url.pathExtension == "tachibk" }
            .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
    }

    private static func files(in root: URL) throws -> [ComicStorageFile] {
        try children(of: root).compactMap { url in
            try Task.checkCancellation()
            guard try isRegularFile(url) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return ComicStorageFile(url: url, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }
    }

    private static func children(of root: URL) throws -> [URL] {
        try validatePath(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
    }

    private static func bytes(in root: URL) throws -> Int64 {
        try validatePath(root)
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, error in failure = error; return false }) else { throw StorageError.unreadable }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        if let failure { throw failure }
        return total
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func validatePath(_ url: URL) throws {
        // /var is itself an OS symlink, so compare relative to the canonical
        // application container instead of rejecting legitimate sandbox paths.
        var current = url.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.path),
               try current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                if current.path == "/var" || current.path == "/tmp" { break }
                throw StorageError.unsafePath
            }
            current.deleteLastPathComponent()
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum StorageError: LocalizedError {
        case unsafePath, invalidChapter, unreadable
        var errorDescription: String? {
            switch self {
            case .unsafePath: "文件路径异常，已跳过。"
            case .invalidChapter: "章节索引损坏，未将该目录列入清理范围。"
            case .unreadable: "无法读取此目录。"
            }
        }
    }
}
