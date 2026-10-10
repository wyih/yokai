import SwiftUI
import Network
import ZIPFoundation
import UniformTypeIdentifiers
import ImageIO
import Combine

struct ChapterDownload: Codable, Identifiable {
    enum State: String, Codable { case queued, downloading, paused, failed, completed }
    enum Interruption: String, Codable { case backgroundTime, system }
    var id = UUID().uuidString
    let sourceID: String
    let manga: SourceManga
    let chapter: SourceChapter
    var state = State.queued
    var completed = 0
    var total = 0
    var error: String?
    var forReading: Bool?
    // completed is the contiguous prefix available to the reader; received
    // includes images finishing out of order during the two-page pipeline.
    var received: Int?
    var interruption: Interruption?
}

@MainActor
final class DownloadStore: ObservableObject {
    @Published private(set) var jobs: [ChapterDownload] = []
    @Published private(set) var wifi = false
    @Published private(set) var backgroundMessage: String?
    private weak var library: ComicLibrary?
    private weak var extensions: ExtensionStore?
    // Match Android: one active chapter per source, at most five sources.
    private var workers: [String: Task<Void, Never>] = [:]
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundExpired = false
    private let continued = DownloadBackgroundExecution()
    private let file: URL
    private let monitor = NWPathMonitor()
    private var extensionObserver: AnyCancellable?
    init(directory: URL? = nil) {
        file = (directory ?? YokaiStorage.support).appendingPathComponent("downloads.json")
        jobs = (try? JSONDecoder().decode([ChapterDownload].self, from: Data(contentsOf: file))) ?? []
        for i in jobs.indices where jobs[i].state == .downloading { jobs[i].state = .queued }
        for i in jobs.indices where jobs[i].state == .paused && jobs[i].error == "后台时间已结束，将在回到 App 后继续。" { jobs[i].interruption = .backgroundTime }
        continued.changed = { [weak self] in self?.backgroundMessage = $0 }
        continued.granted = { [weak self] in
            guard let self else { return }
            self.backgroundExpired = false; self.endBackground(); self.continued.report(self.jobs); self.resumeWorker()
        }
        continued.expired = { [weak self] ids in
            guard let self else { return }
            self.interruptForBackground(.system, ids: ids)
        }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.wifi = path.status == .satisfied && path.usesInterfaceType(.wifi); self?.resumeWorker() }
        }
        monitor.start(queue: DispatchQueue(label: "com.wyih.yokai.download-network"))
    }
    func connect(library: ComicLibrary, extensions: ExtensionStore) {
        self.library = library; self.extensions = extensions
        extensionObserver = extensions.$busy.dropFirst().sink { [weak self] busy in
            if !busy { Task { @MainActor in self?.resumeWorker() } }
        }
        resumeWorker()
    }
    @discardableResult func enqueue(source: MangaSource, manga: SourceManga, chapter: SourceChapter, forReading: Bool = false, userInitiated: Bool = true) -> String {
        if let i = jobs.firstIndex(where: { $0.sourceID == source.id && $0.manga.url == manga.url && $0.chapter.url == chapter.url }) {
            if jobs[i].state == .completed,
               let library,
               !FileManager.default.fileExists(atPath: library.chapterDirectory(bookID: ComicLibrary.hash(source.id + "\n" + manga.url), chapterURL: chapter.url).appendingPathComponent("chapter.json").path) {
                jobs[i].state = .queued; jobs[i].completed = 0
            } else if jobs[i].state != .completed && jobs[i].state != .downloading { jobs[i].state = .queued }
            if forReading { jobs[i].forReading = true }
            jobs[i].error = nil; jobs[i].interruption = nil
            let id = jobs[i].id; save()
            if userInitiated && !forReading && jobs[i].state != .completed { continued.request([id], jobs: jobs) }
            resumeWorker(); return id
        }
        let job = ChapterDownload(sourceID: source.id, manga: manga, chapter: chapter, forReading: forReading)
        if forReading { jobs.insert(job, at: 0) } else { jobs.append(job) }
        save()
        if userInitiated && !forReading { continued.request([job.id], jobs: jobs) }
        resumeWorker(); return job.id
    }
    func pause(_ id: String) { update(id) { if $0.state != .completed { $0.state = .paused; $0.interruption = nil; $0.error = nil } } }
    func resume(_ id: String, userInitiated: Bool = true) {
        update(id) { if $0.state != .completed { $0.state = .queued; $0.error = nil; $0.interruption = nil } }
        backgroundExpired = false
        if userInitiated && jobs.contains(where: { $0.id == id && $0.state == .queued }) { continued.request([id], jobs: jobs) }
        resumeWorker()
    }
    func pauseAll() { for i in jobs.indices where jobs[i].state == .queued || jobs[i].state == .downloading { jobs[i].state = .paused; jobs[i].interruption = nil; jobs[i].error = nil }; save() }
    func resumeAll(userInitiated: Bool = true) {
        var ids = Set<String>()
        for i in jobs.indices where jobs[i].state == .paused || jobs[i].state == .failed { jobs[i].state = .queued; jobs[i].error = nil; jobs[i].interruption = nil; ids.insert(jobs[i].id) }
        backgroundExpired = false; save(); if userInitiated { continued.request(ids, jobs: jobs) }; resumeWorker()
    }
    func cancel(_ id: String) { jobs.removeAll { $0.id == id }; save() }
    func clearCompleted() { jobs.removeAll { $0.state == .completed }; save() }
    func move(from: IndexSet, to: Int) { jobs.move(fromOffsets: from, toOffset: to); save() }
    func deleteChapter(bookID: String, chapterURL: String) {
        guard let library else { return }
        do {
            let folder = library.chapterDirectory(bookID: bookID, chapterURL: chapterURL)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            if let book = library.books.first(where: { $0.id == bookID }) {
                jobs.removeAll { $0.sourceID == book.origin?.sourceID && $0.manga.url == book.origin?.mangaURL && $0.chapter.url == chapterURL }; save()
            }
            library.downloadedChapterChanged(bookID: bookID, chapterURL: chapterURL, available: false)
        } catch { library.errorMessage = error.localizedDescription }
    }
    func deleteIfAllowed(bookID: String, chapterURL: String) {
        guard let library, let book = library.books.first(where: { $0.id == bookID }) else { return }
        let excluded = YokaiStorage.defaults.stringArray(forKey: "downloads.removeExcludedCategories") ?? []
        if (book.categories ?? []).contains(where: { excluded.contains($0) }) { return }
        if !YokaiStorage.defaults.bool(forKey: "downloads.removeBookmarks"),
           book.chapters?.first(where: { $0.url == chapterURL })?.bookmarked == true || book.bookmarks.contains(where: { !$0.deleted && $0.chapterURL == chapterURL }) { return }
        deleteChapter(bookID: bookID, chapterURL: chapterURL)
    }
    func leftChapter(bookID: String, chapterURL: String?, order: [String]) {
        let slots = YokaiStorage.defaults.object(forKey: "downloads.removeAfterRead") as? Int ?? -1
        guard slots >= 0, let chapterURL, let index = order.firstIndex(of: chapterURL), index >= slots,
              let library, let book = library.books.first(where: { $0.id == bookID }) else { return }
        let candidate = order[index - slots]
        if book.chapters?.first(where: { $0.url == candidate })?.completed == true { deleteIfAllowed(bookID: bookID, chapterURL: candidate) }
    }
    func foreground() {
        backgroundExpired = false
        endBackground()
        for i in jobs.indices where jobs[i].state == .paused && jobs[i].interruption == .backgroundTime { jobs[i].state = .queued; jobs[i].error = nil; jobs[i].interruption = nil }
        save(); resumeWorker()
    }
    func beginBackground() {
        #if !targetEnvironment(macCatalyst)
        guard !workers.isEmpty, !continued.active, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "漫画下载") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.continued.active && UIApplication.shared.applicationState != .active {
                    self.interruptForBackground(.backgroundTime)
                }
                self.endBackground()
            }
        }
        #endif
    }
    func interruptForBackground(_ reason: ChapterDownload.Interruption, ids: Set<String>? = nil) {
        backgroundExpired = reason == .backgroundTime || UIApplication.shared.applicationState != .active
        for i in jobs.indices where (ids == nil || ids!.contains(jobs[i].id)) && (jobs[i].state == .queued || jobs[i].state == .downloading) {
            jobs[i].state = .paused; jobs[i].interruption = reason
            jobs[i].error = reason == .backgroundTime ? "后台时间已结束，将在回到 App 后继续。" : "后台任务已停止，可在下载队列中继续。"
        }
        save()
    }
    private func endBackground() { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid } }
    private func save() {
        do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(jobs).write(to: file, options: .atomic) }
        catch { library?.errorMessage = "无法保存下载队列：" + error.localizedDescription }
        continued.report(jobs)
    }
    private func update(_ id: String, _ change: (inout ChapterDownload) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }; change(&jobs[i]); save()
    }
    private func allowed(_ job: ChapterDownload) -> Bool {
        #if !targetEnvironment(macCatalyst)
        if UIApplication.shared.applicationState == .background {
            if continued.active && !continued.contains(job.id) { return false }
            if !continued.active && backgroundTask == .invalid { return false }
        }
        #endif
        return job.forReading == true || wifi || !YokaiStorage.defaults.bool(forKey: "downloads.wifiOnly")
    }
    private func resumeWorker() {
        guard library != nil, extensions?.busy == false, !backgroundExpired else { return }
        while workers.count < 5 {
            let queued = jobs.filter { $0.state == .queued && workers[$0.sourceID] == nil && allowed($0) }
            guard let job = queued.first(where: { $0.forReading == true }) ?? queued.first else { break }
            workers[job.sourceID] = Task {
                await run(job)
                workers.removeValue(forKey: job.sourceID)
                continued.report(jobs)
                // Resume can arrive while an old paused request is unwinding.
                resumeWorker()
                if workers.isEmpty { endBackground() }
            }
        }
    }
    private func run(_ job: ChapterDownload) async {
        guard let library, let source = extensions?.sources.first(where: { $0.id == job.sourceID }) else { update(job.id) { $0.state = .failed; $0.error = "请安装此漫画源插件。" }; return }
        update(job.id) { $0.state = .downloading; $0.error = nil }
        var pageCheckpoint: URL?
        do {
            let book = library.addOnline(job.manga, source: source, favorite: false)
            let directory = library.chapterDirectory(bookID: book.id, chapterURL: job.chapter.url)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pageFile = directory.appendingPathComponent("pages.json")
            pageCheckpoint = pageFile
            let pages: [SourcePage]
            if let data = try? Data(contentsOf: pageFile), let cached = try? JSONDecoder().decode([SourcePage].self, from: data), !cached.isEmpty {
                pages = cached
            } else {
                let fetched = try await SourceEngine.call("pages", ["source": source.id, "chapter": SourceEngine.object(job.chapter)], as: [SourcePage].self)
                pages = fetched.enumerated().map { SourcePage(index: $0.offset, url: $0.element.url, imageURL: $0.element.imageURL) }
                try JSONEncoder().encode(pages).write(to: pageFile, options: .atomic)
            }
            guard !pages.isEmpty else { throw SourceError.message("此章节没有可阅读的图片。") }
            guard canContinue(job.id) else { return }
            var ready = Set(pages.indices.filter { ChapterArchive.imageSize(directory: directory, index: $0) != nil })
            updateProgress(job.id, ready: ready, total: pages.count)
            let missing = pages.indices.filter { !ready.contains($0) }
            try await withThrowingTaskGroup(of: Int.self) { group in
                var remaining = missing.makeIterator()
                @MainActor func addNext() {
                    if canContinue(job.id), let index = remaining.next() {
                        group.addTask { try await Self.fetchImage(sourceID: source.id, page: pages[index], index: index, directory: directory) }
                    }
                }
                addNext(); addNext()
                while let index = try await group.next() {
                    ready.insert(index); updateProgress(job.id, ready: ready, total: pages.count)
                    if canContinue(job.id) { addNext() } else { group.cancelAll() }
                }
            }
            guard canContinue(job.id), ready.count == pages.count else { return }
            if YokaiStorage.defaults.bool(forKey: "downloads.saveCBZ") {
                let archive = try await Task.detached {
                    if ChapterArchive.hasCompleteArchive(directory: directory, count: pages.count) { return directory.appendingPathComponent("chapter.cbz") }
                    return try ChapterArchive.create(directory: directory, count: pages.count)
                }.value
                guard canContinue(job.id) else { return }
                if FileManager.default.fileExists(atPath: archive.path) {
                    for index in pages.indices {
                        let original = directory.appendingPathComponent(String(format: "%06d", index))
                        if FileManager.default.fileExists(atPath: original.path) { try FileManager.default.removeItem(at: original) }
                    }
                }
            }
            try JSONEncoder().encode(CachedChapter(chapter: job.chapter, pageCount: pages.count)).write(to: directory.appendingPathComponent("chapter.json"), options: .atomic)
            library.downloadedChapterChanged(bookID: book.id, chapterURL: job.chapter.url, available: true)
            update(job.id) { $0.state = .completed }
        } catch {
            // An expired, cancelled or user-paused batch must keep that state.
            if jobs.first(where: { $0.id == job.id })?.state == .downloading {
                // Retry obtains fresh signed URLs / mirror choices after a real
                // source failure, while keeping successfully downloaded images.
                if let pageCheckpoint { try? FileManager.default.removeItem(at: pageCheckpoint) }
                update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
        }
    }
    private func canContinue(_ id: String) -> Bool {
        guard let current = jobs.first(where: { $0.id == id }), current.state == .downloading, !backgroundExpired else { return false }
        if !allowed(current) { update(id) { $0.state = .queued }; return false }
        return true
    }
    private func updateProgress(_ id: String, ready: Set<Int>, total: Int) {
        var prefix = 0
        while ready.contains(prefix) { prefix += 1 }
        update(id) { $0.total = total; $0.completed = prefix; $0.received = ready.count }
    }
    private static func fetchImage(sourceID: String, page: SourcePage, index: Int, directory: URL) async throws -> Int {
        try Task.checkCancellation()
        let output = directory.appendingPathComponent(String(format: "%06d", index))
        let temporary = output.appendingPathExtension("part")
        do {
            let _: Bool = try await SourceEngine.call("image", ["source": sourceID, "page": SourceEngine.object(page), "path": temporary.path], as: Bool.self)
            guard UIImage(contentsOfFile: temporary.path) != nil else { throw SourceError.message("漫画源返回了无法读取的图片，请更新插件后重试。") }
            if FileManager.default.fileExists(atPath: output.path) { _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: output) }
            return index
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
}

enum ChapterArchive {
    static func hasCompleteArchive(directory: URL, count: Int) -> Bool {
        guard let archive = try? Archive(url: directory.appendingPathComponent("chapter.cbz"), accessMode: .read), count > 0 else { return false }
        let names = Set(archive.filter { $0.uncompressedSize > 0 }.map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent })
        return (0..<count).allSatisfy { names.contains(String(format: "%06d", $0)) }
    }
    static func imageSize(directory: URL, index: Int) -> CGSize? {
        let name = String(format: "%06d", index)
        var source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil)
        if source == nil, let archive = try? Archive(url: directory.appendingPathComponent("chapter.cbz"), accessMode: .read, pathEncoding: nil),
           let entry = archive.first(where: { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent == name }) {
            var data = Data()
            guard (try? archive.extract(entry, consumer: { data.append($0) })) != nil else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }
    static func create(directory: URL, count: Int, destination: URL? = nil) throws -> URL {
        let destination = destination ?? directory.appendingPathComponent("chapter.cbz")
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".cbz")
        do {
            let archive = try Archive(url: temporary, accessMode: .create)
            for index in 0..<count {
                let input = directory.appendingPathComponent(String(format: "%06d", index))
                guard let image = CGImageSourceCreateWithURL(input as CFURL, nil), let type = CGImageSourceGetType(image) else { throw SourceError.message("章节图片不完整。") }
                let ext = UTType(type as String)?.preferredFilenameExtension ?? "jpg"
                try archive.addEntry(with: String(format: "%06d", index) + "." + ext, fileURL: input)
            }
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
            return destination
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    static func image(directory: URL, index: Int) -> UIImage? {
        let filename = String(format: "%06d", index)
        if let image = UIImage(contentsOfFile: directory.appendingPathComponent(filename).path) { return image }
        guard let archive = try? Archive(url: directory.appendingPathComponent("chapter.cbz"), accessMode: .read, pathEncoding: nil), let entry = archive.first(where: { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent == filename }) else { return nil }
        var data = Data()
        guard (try? archive.extract(entry, consumer: { data.append($0) })) != nil else { return nil }
        return UIImage(data: data)
    }
}

struct CachedChapter: Codable { let chapter: SourceChapter; let pageCount: Int }

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var library: ComicLibrary
    @State private var deleting: ChapterDownload?
    var body: some View {
        List {
            if let message = downloads.backgroundMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
            ForEach(downloads.jobs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.manga.title).font(.headline); Text(job.chapter.name).font(.subheadline)
                    HStack { Text(label(job.state)); Spacer(); Text("\(job.received ?? job.completed) / \(job.total)").monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if job.state == .queued || job.state == .downloading { Button("暂停") { downloads.pause(job.id) } }
                    if job.state == .paused || job.state == .failed { Button("继续下载") { downloads.resume(job.id) } }
                }.padding(.vertical, 8).contextMenu {
                    if job.state == .completed { Button("删除下载", role: .destructive) { deleting = job } }
                    else { Button("取消任务", role: .destructive) { downloads.cancel(job.id) } }
                }
            }.onMove { downloads.move(from: $0, to: $1) }
        }.overlay { if downloads.jobs.isEmpty { ContentUnavailableView("没有下载任务", systemImage: "arrow.down.circle") } }
        .navigationTitle("下载队列").toolbar {
            EditButton()
            Menu("队列操作", systemImage: "ellipsis") { Button("暂停全部") { downloads.pauseAll() }; Button("继续全部") { downloads.resumeAll() }; Button("清除已完成记录") { downloads.clearCompleted() }; NavigationLink("下载设置") { DownloadSettingsView() } }
        }
        .alert("删除下载？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let job = deleting { downloads.deleteChapter(bookID: ComicLibrary.hash(job.sourceID + "\n" + job.manga.url), chapterURL: job.chapter.url) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("书架、阅读进度和书签会保留。") }
    }
    private func label(_ state: ChapterDownload.State) -> String {
        switch state { case .queued: "等待下载"; case .downloading: "正在下载"; case .paused: "已暂停"; case .failed: "下载失败"; case .completed: "已下载" }
    }
}

struct DownloadSettingsView: View {
    @EnvironmentObject private var library: ComicLibrary
    @AppStorage("downloads.wifiOnly", store: YokaiStorage.defaults) private var wifi = false
    @AppStorage("downloads.saveCBZ", store: YokaiStorage.defaults) private var cbz = false
    @AppStorage("downloads.newChapters", store: YokaiStorage.defaults) private var newChapters = false
    @AppStorage("downloads.aheadChapters", store: YokaiStorage.defaults) private var ahead = 0
    @AppStorage("downloads.removeAfterRead", store: YokaiStorage.defaults) private var removal = -1
    @AppStorage("downloads.removeAfterMarked", store: YokaiStorage.defaults) private var marked = false
    @AppStorage("downloads.removeBookmarks", store: YokaiStorage.defaults) private var bookmarks = false
    @AppStorage("downloads.removedPolicy", store: YokaiStorage.defaults) private var removed = 0
    @State private var excluded: [String] = []
    var body: some View {
        Form {
            Section { Toggle("仅通过 Wi-Fi 下载", isOn: $wifi); Toggle("将章节保存为 CBZ", isOn: $cbz) }
            Section("自动下载") {
                Toggle("下载书架的新章节", isOn: $newChapters)
                if newChapters { CategoryPreferencePicker(title: "仅下载这些分类的新章节", key: "downloads.newCategories"); CategoryPreferencePicker(title: "排除分类", key: "downloads.newExcludedCategories") }
                Stepper("阅读时提前下载 \(ahead) 章", value: $ahead, in: 0...10)
            }
            Section("阅读后删除") {
                Toggle("标记为已读后删除", isOn: $marked)
                Picker("阅读后删除", selection: $removal) { Text("从不").tag(-1); Text("离开已读章节时").tag(0); ForEach(1...4, id: \.self) { Text("保留最近 \($0) 个已读章节").tag($0) } }
                Toggle("允许删除有书签的章节", isOn: $bookmarks)
                ForEach(library.categoryNames, id: \.self) { category in
                    Toggle("保留“\(category)”的下载", isOn: Binding(get: { excluded.contains(category) }, set: { value in if value { excluded.append(category) } else { excluded.removeAll { $0 == category } }; YokaiStorage.defaults.set(excluded, forKey: "downloads.removeExcludedCategories") }))
                }
            }
            Section("图源删除的章节") {
                Picker("下载处理", selection: $removed) { Text("在章节页询问").tag(0); Text("始终保留").tag(1); Text("自动删除下载").tag(2) }
            }
        }.navigationTitle("下载设置")
        .task { excluded = YokaiStorage.defaults.stringArray(forKey: "downloads.removeExcludedCategories") ?? [] }
    }
}
