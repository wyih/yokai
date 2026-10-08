import Foundation

enum ReaderModule: String, CaseIterable, Identifiable {
    case yokai, qiye
    var id: String { rawValue }
    var title: String { self == .yokai ? "Yōkai · 漫画" : "栖页 · 阅读" }
    var symbol: String { self == .yokai ? "books.vertical" : "book" }
}

enum HubRoute {
    static func module(for url: URL) -> ReaderModule? {
        guard url.scheme?.lowercased() == "readinghub" else { return nil }
        return ReaderModule(rawValue: (url.host ?? "").lowercased())
    }
    static func fileModule(for url: URL) -> ReaderModule? {
        guard url.isFileURL else { return nil }
        switch url.pathExtension.lowercased() {
        case "pdf", "cbz": return nil // Supported by both readers: ask once for this file.
        case "apk", "jar", "tachibk", "tmb", "json", "gz", "zip",
             "jpg", "jpeg", "png", "webp", "gif", "heic", "avif": return .yokai
        default: return .qiye
        }
    }
}
