#if DEBUG && targetEnvironment(macCatalyst)
import SwiftUI
import ZIPFoundation

@MainActor
enum DesktopCheck {
    static var directory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--desktop-check"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    static func run(library: ComicLibrary, extensions: ExtensionStore) async {
        guard let directory else { return }
        var report: [String: Any] = [:]
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw SourceError.message(message) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let expected = try JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: Bundle.main.url(forResource: "BundledExtensions", withExtension: "json")!))
            try require(Set(expected.map(\.package)).isSubset(of: Set(extensions.sources.filter { $0.error == nil }.map(\.package))),
                        extensions.sources.compactMap(\.error).joined(separator: "\n"))
            report["sources"] = extensions.sources.compactMap(\.name)
            let sample = "{\"desktopCheck\":\"你好\"}"
            _ = try DesktopKeychain.write(sample, service: "com.wyih.yokai.extension-preferences", account: "desktop-check")
            let secret = try DesktopKeychain.read(forService: "com.wyih.yokai.extension-preferences", account: "desktop-check")
            try require(secret == sample, "系统钥匙串读写失败")
            report["keychain"] = true
            let parallel = try await withThrowingTaskGroup(of: Bool.self) { group in
                for index in 0..<2 {
                    group.addTask {
                        let account = "desktop-check-\(index)"
                        _ = try DesktopKeychain.write(sample, service: "com.wyih.yokai.extension-preferences", account: account)
                        return try DesktopKeychain.read(forService: "com.wyih.yokai.extension-preferences", account: account) == sample
                    }
                }
                var successful = true
                for try await value in group { successful = successful && value }
                return successful
            }
            try require(parallel, "并发钥匙串请求失败")
            report["parallelKeychain"] = true
            let pages = directory.appendingPathComponent("Pages")
            try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
            for index in 0..<3 {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1200)).image { context in
                    UIColor(red: 0.12 + Double(index) * 0.08, green: 0.2, blue: 0.4, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 800, height: 1200))
                    ("Yōkai\nMac 阅读测试\n第 \(index + 1) 页" as NSString).draw(at: CGPoint(x: 80, y: 140), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.white])
                }
                try image.pngData()!.write(to: pages.appendingPathComponent("\(index).png"))
            }
            let archive = directory.appendingPathComponent("Mac 阅读测试.cbz")
            if !FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.zipItem(at: pages, to: archive) }
            if !library.books.contains(where: { $0.title == "Mac 阅读测试" }) { await library.importFiles([archive]) }
            try require(library.errorMessage == nil, library.errorMessage ?? "漫画导入失败")
            guard let book = library.books.first(where: { $0.title == "Mac 阅读测试" }) else { throw SourceError.message("本地漫画未出现在书架") }
            try require(book.pageCount == 3, "CBZ 页数错误")
            try require(ChapterArchive.image(directory: library.directory(for: book), index: 2) != nil, "导入图片无法解码")
            library.setPage(1, for: book.id)
            try await library.flushPendingSaves()
            let restored = ComicLibrary(root: library.root)
            try require(restored.books.first(where: { $0.id == book.id })?.lastPage == 1, "重启后阅读进度丢失")
            report["cbzPages"] = book.pageCount; report["persistedPage"] = 1
            if ProcessInfo.processInfo.arguments.contains("--online") {
                guard let source = extensions.sources.first(where: { $0.package.hasSuffix(".hotmangas") }) else { throw SourceError.message("HotMangas 未加载") }
                let listing = try await SourceEngine.call("popular", ["source": source.id], as: SourceResults.self)
                guard let manga = listing.manga.first else { throw SourceError.message("在线目录为空") }
                let details = try await SourceEngine.call("details", ["source": source.id, "manga": try SourceEngine.object(manga)], as: SourceDetails.self)
                guard let chapter = details.chapters.last else { throw SourceError.message("章节目录为空") }
                let images = try await SourceEngine.call("pages", ["source": source.id, "chapter": try SourceEngine.object(chapter)], as: [SourcePage].self)
                guard let image = images.first else { throw SourceError.message("章节图片目录为空") }
                let target = directory.appendingPathComponent("online-image")
                let _: Bool = try await SourceEngine.call("image", ["source": source.id, "page": try SourceEngine.object(image), "path": target.path], as: Bool.self)
                try require(UIImage(contentsOfFile: target.path) != nil, "在线图片无法解码")
                report["online"] = ["source": source.name ?? "", "catalogCount": listing.manga.count, "chapterCount": details.chapters.count, "pageCount": images.count]
            }
            report["passed"] = true
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
}
#endif
