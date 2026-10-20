#if DEBUG && targetEnvironment(simulator)
import UIKit
import ImageIO

enum ReaderAnimationChecks {
    @MainActor static func prepare(library: ComicLibrary) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw SourceError.message(message) }
        }
        // Two solid frames generated locally, with unequal durations (200/300 ms).
        let webp = Data(base64Encoded: "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAdwAAswAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAHcAALMAAMgAAAJWUDhMDwAAAC93wCwABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAHcAALMAACwBAABWUDhMDwAAAC93wCwABxDR//4HIqL/AQA=")!
        let animation = ReaderPageImage(data: webp)?.animation
        try require(animation?.durations == [0.2, 0.3] && animation?.loopCount == 0, "WebP timing or loop count changed")
        let red = animation!.frame(at: 0)!, blue = animation!.frame(at: 1)!
        try require(red.pngData() != blue.pngData(), "Animation frames must differ")
        try require(ReaderPageImage(data: red.pngData()!)?.animation == nil, "Static PNG treated as animation")
        try require(ReaderPageImage(data: Data("invalid".utf8)) == nil, "Invalid image accepted")
        for (type, dictionary, delay, loops) in [
            ("com.compuserve.gif", kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFLoopCount),
            ("public.png", kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGLoopCount)
        ] {
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, type as CFString, 2, nil)!
            CGImageDestinationSetProperties(destination, [dictionary: [loops: 0]] as CFDictionary)
            for (index, frame) in [red, blue].enumerated() {
                CGImageDestinationAddImage(destination, frame.cgImage!, [dictionary: [delay: [0.2, 0.3][index]]] as CFDictionary)
            }
            try require(CGImageDestinationFinalize(destination), "Fixture encoding failed")
            let decoded = ReaderPageImage(data: data as Data)?.animation
            let timingMatches = decoded.map { value in
                value.durations.count == 2 && zip(value.durations, [0.2, 0.3]).allSatisfy { abs($0 - $1) < 0.000001 }
            } ?? false
            try require(timingMatches && decoded?.loopCount == 0, "GIF/APNG timing changed")
        }
        let mode = ProcessInfo.processInfo.environment["YOKAI_ANIMATION_MODE"] == "ltr" ? "ltr" : "webtoon"
        var book = ComicBook(id: ComicLibrary.hash("reader-animation"), title: "动图播放验证", format: .images, pageCount: 2, importedAt: Date())
        book.readerSettings = MangaReaderSettings(mode: mode, trimBorders: true, layout: "single")
        let directory = library.directory(for: book)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loose = directory.appendingPathComponent("000000")
        try webp.write(to: loose)
        try red.pngData()!.write(to: directory.appendingPathComponent("000001"))
        try require(ChapterArchive.readerImage(directory: directory, index: 0)?.animation?.durations.count == 2, "Loose page lost animation")
        _ = try ChapterArchive.create(directory: directory, count: 2)
        try FileManager.default.removeItem(at: loose)
        try require(ChapterArchive.readerImage(directory: directory, index: 0)?.animation?.durations.count == 2, "CBZ page lost animation")
        // Local-book availability uses the first loose page; downloaded chapters use CBZ metadata.
        try webp.write(to: loose)
        let captured = library.snapshot()
        var state = captured
        state.books.removeAll { $0.id == book.id }
        state.books.append(book)
        library.acceptSync(state, captured: captured)
        YokaiStorage.defaults.set(0, forKey: "reader.sidePadding")
        YokaiStorage.defaults.set(false, forKey: "reader.grayscale")
        YokaiStorage.defaults.set(false, forKey: "reader.inverted")
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("reader-animation-sample.webp")
        var originalFrames = 0
        if let data = try? Data(contentsOf: sample) {
            let decoded = ReaderPageImage(data: data)?.animation
            try require(decoded?.durations.count == 49 && decoded?.loopCount == 0, "Original chapter WebP lost frames")
            try require(decoded?.frame(at: 0)?.pngData() != decoded?.frame(at: 24)?.pngData(), "Original chapter WebP is frozen")
            originalFrames = decoded!.durations.count
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "originalWebPFrames": originalFrames,
            "checks": ["WebP/GIF/APNG timing and loops", "distinct decoded frames", "static and invalid images", "loose and CBZ playback"]])
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("reader-animation-check.json"), options: .atomic)
    }
}
#endif
