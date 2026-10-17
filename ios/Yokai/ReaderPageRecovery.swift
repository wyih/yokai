import UIKit
import ZIPFoundation

enum ReaderPageFailure {
    case missing, unreadable

    static func inspect(directory: URL, index: Int) -> Self {
        let name = String(format: "%06d", index)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) { return .unreadable }
        let file = directory.appendingPathComponent("chapter.cbz")
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard let archive = try? Archive(url: file, accessMode: .read, pathEncoding: nil) else { return .unreadable }
        return archive.contains { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent == name } ? .unreadable : .missing
    }
}

enum ReaderPageRecovery {
    // Completed downloads cannot be resumed. Repair only this page, keeping the other
    // pages and any CBZ intact; ChapterArchive reads a repaired loose image first.
    static func reload(sourceID: String, chapter: SourceChapter, index: Int, directory: URL) async throws {
        let pages = try await SourceEngine.call("pages", ["source": sourceID, "chapter": SourceEngine.object(chapter)], as: [SourcePage].self)
        guard pages.indices.contains(index) else { throw SourceError.message("图源中已找不到这一页，请打开章节网页查看。") }
        let fetched = pages[index]
        let page = SourcePage(index: index, url: fetched.url, imageURL: fetched.imageURL)
        let output = directory.appendingPathComponent(String(format: "%06d", index))
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".retry")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let _: Bool = try await SourceEngine.call("image", ["source": sourceID, "page": SourceEngine.object(page), "path": temporary.path], as: Bool.self)
        try Task.checkCancellation()
        guard UIImage(contentsOfFile: temporary.path) != nil else { throw SourceError.message("图源仍返回无法解码的图片，请打开章节网页查看或更新图源。") }
        if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: output) }
    }
}

struct ReaderChapterWebPage: Identifiable {
    let id = UUID()
    let source: MangaSource
    let address: URL

    static func isWebReference(_ value: String) -> Bool {
        if value.hasPrefix("/") { return true }
        return address(value, base: nil) != nil
    }

    static func address(_ value: String, base: String?) -> URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Opaque chapter IDs are common in extensions; never turn one into a guessed URL.
        let url: URL?
        if value.hasPrefix("/"), let base = base.flatMap(URL.init(string:)) {
            url = URL(string: value, relativeTo: base)?.absoluteURL
        } else {
            url = URL(string: value)
        }
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
