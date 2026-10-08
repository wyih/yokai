#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

// Launches existing screens for screenshots when the desktop UI is unavailable.
// No preview screen or fixture assets are enabled in a device/Release build.
struct LocalPreviewView: View {
    let screen: String
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var path: [String]
    init(screen: String) { self.screen = screen; _path = State(initialValue: [screen]) }
    private var book: ComicBook? { library.books.first { $0.origin?.mangaURL == "/local-ui-check" } }
    var body: some View {
        if screen == "source-settings", let source = extensions.sources.first {
            LibraryView().sheet(isPresented: .constant(true)) { SourcePreferencesView(source: source) }
        } else if screen == "reader", let book {
            ReaderView(book: book, directory: library.directory(for: book))
        } else {
            NavigationStack(path: $path) {
                Color.clear.navigationTitle(screen == "details" ? "书架" : screen == "webdav" ? "备份与恢复" : "设置")
                    .navigationDestination(for: String.self) { route in
                        switch route {
                        case "details": if let book { BookDetailsView(book: book) }
                        case "backup": BackupSettingsView()
                        case "webdav": WebDAVSettingsView()
                        case "reader-settings": ReaderDefaultsView()
                        case "source-settings": if let source = extensions.sources.first { SourcePreferencesView(source: source) }
                        default: EmptyView()
                        }
                    }
            }
        }
    }
}

extension LocalUIFixture {
    @MainActor static func checkReaderBrightness() {
        guard enabled, ProcessInfo.processInfo.arguments.contains("-YokaiBrightnessCheck") else { return }
        // The simulator always reports UIScreen.brightness == 0.5. Exercise the
        // production ownership logic through its native property boundary.
        var level: CGFloat = 0.8
        var writes = 0
        let controller = ReaderBrightness(read: { level }, write: { level = $0; writes += 1 })
        var passed: [String] = []
        func expect(_ value: CGFloat, _ name: String) throws {
            guard abs(level - value) <= 0.005 else {
                throw SourceError.message("\(name): expected \(value), got \(level)")
            }
            passed.append(name)
        }
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("UIFixture/brightness-check.json")
        do {
            controller.apply(enabled: false, value: 0.3)
            level = 0.65
            controller.apply(enabled: false, value: 0.3); controller.restore()
            guard writes == 0 else { throw SourceError.message("System mode wrote to screen brightness") }
            try expect(0.65, "System mode preserves a manual brightness change")
            level = 0.8
            controller.apply(enabled: true, value: 0.3)
            try expect(0.3, "Explicit custom brightness applies")
            controller.apply(enabled: true, value: 0.3); controller.restore()
            try expect(0.8, "Repeated appearance preserves the original brightness")
            controller.apply(enabled: true, value: 0.3)
            level = 0.65; controller.restore()
            try expect(0.65, "Exiting preserves a manual system adjustment")
            controller.apply(enabled: true, value: -0.5)
            try expect(0.01, "Negative custom brightness uses Android's minimum")
            controller.apply(enabled: true, value: 0)
            try expect(0.65, "Zero releases the custom override")
            controller.apply(enabled: true, value: 0.3)
            controller.apply(enabled: false, value: 0.3)
            try expect(0.65, "Disabling custom brightness restores the system value")
            controller.apply(enabled: true, value: 0.3); controller.restore()
            try expect(0.65, "Background release restores the system value")
            try JSONSerialization.data(withJSONObject: ["passed": passed, "brightnessWrites": writes, "usesSimulatedScreenProperty": true], options: [.prettyPrinted]).write(to: file)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["passed": passed, "error": error.localizedDescription], options: [.prettyPrinted]).write(to: file)
        }
    }

    static var previewScreen: String? {
        guard enabled, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-YokaiPreviewScreen"),
              ProcessInfo.processInfo.arguments.indices.contains(index + 1) else { return nil }
        return ProcessInfo.processInfo.arguments[index + 1]
    }
    @MainActor static func preparePreviewImages(library: ComicLibrary) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let palette: [UIColor] = [.systemIndigo, .systemTeal, .systemOrange, .systemPink, .systemBlue, .systemGreen]
        for (index, book) in library.books.filter({ $0.inLibrary != false }).enumerated() {
            let color = palette[index % palette.count]
            let cover = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
                UIColor.white.withAlphaComponent(0.12).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 120, y: 220, width: 400, height: 400))
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white]
                ("示例漫画" as NSString).draw(at: CGPoint(x: 34, y: 56), withAttributes: attributes)
                (String(format: "%02d", index + 1) as NSString).draw(at: CGPoint(x: 34, y: 140), withAttributes: [.font: UIFont.systemFont(ofSize: 96, weight: .thin), .foregroundColor: UIColor.white])
                ("YŌKAI · UI PREVIEW" as NSString).draw(at: CGPoint(x: 34, y: 530), withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .medium), .foregroundColor: UIColor.white])
            }
            library.changeCover(book.id, image: cover)
        }
        if let book = library.books.first(where: { $0.origin?.mangaURL == "/local-ui-check" }) {
            let directory = library.directory(for: book)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for index in 0..<book.pageCount {
                let trace = ProcessInfo.processInfo.arguments.contains("-YokaiReaderTrace")
                let height = trace ? (index == book.pageCount - 1 ? 200 : index == 9 ? 500 : 1800 + (index % 3) * 400) : 900
                let page = UIGraphicsImageRenderer(size: CGSize(width: 600, height: height), format: format).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: height))
                    ("阅读页 \(index + 1)" as NSString).draw(at: CGPoint(x: 32, y: 32), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.darkGray])
                    for panel in 0..<3 {
                        UIColor(white: 0.94 - CGFloat(panel) * 0.05, alpha: 1).setFill()
                        context.fill(CGRect(x: 24, y: 110 + panel * 242, width: 552, height: 220))
                        ("示例图片" as NSString).draw(at: CGPoint(x: 220, y: 195 + panel * 242), withAttributes: [.font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.gray])
                    }
                }
                try page.pngData()!.write(to: directory.appendingPathComponent(String(format: "%06d", index)), options: .atomic)
            }
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try Data((previewScreen ?? "").utf8).write(to: documents.appendingPathComponent("UIFixture/preview-ready"), options: .atomic)
    }
}
#endif
