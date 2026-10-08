import SwiftUI

struct ChapterUpdate: Codable, Identifiable {
    var id: String { bookID + "\n" + chapter.url }
    let bookID: String
    let chapter: SourceChapter
    let foundAt: Date
}

@MainActor final class LibraryActivity: ObservableObject {
    private struct State: Codable { var chapters: [String: [SourceChapter]] = [:]; var updates: [ChapterUpdate] = []; var checkedAt: Date? }
    @Published private var state = State()
    @Published var busy = false
    @Published var errors: [String] = []
    private let file: URL
    var updates: [ChapterUpdate] { state.updates.sorted { $0.foundAt > $1.foundAt } }
    var checkedAt: Date? { state.checkedAt }
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("activity.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
    }
    func refresh(library: ComicLibrary, extensions: ExtensionStore, downloads: DownloadStore, automatic: Bool = false) async {
        guard !busy else { return }; busy = true; errors = []
        defer { busy = false }
        for book in library.books where book.inLibrary != false {
            if Task.isCancelled { return }
            if automatic && !shouldUpdate(book) { continue }
            guard let origin = book.origin else { continue }
            guard let source = extensions.sources.first(where: { $0.id == origin.sourceID }) else { errors.append(book.title + "：源插件尚未安装"); continue }
            do {
                let manga = SourceManga(url: origin.mangaURL, title: book.title, thumbnail: origin.thumbnail, memo: origin.mangaMemo)
                let result = try await SourceEngine.call("details", ["source": source.id, "manga": SourceEngine.object(manga)], as: SourceDetails.self)
                let old = state.chapters[book.id] ?? library.cachedDetails(for: book)?.chapters
                var additions: [SourceChapter] = []
                if let old {
                    let known = Set(old.map(\.url)), displayed = Set(state.updates.map(\.id))
                    for chapter in result.chapters where !known.contains(chapter.url) && !displayed.contains(book.id + "\n" + chapter.url) {
                        state.updates.append(ChapterUpdate(bookID: book.id, chapter: chapter, foundAt: Date()))
                        additions.append(chapter)
                    }
                } else {
                    for chapter in result.chapters where chapter.uploaded > Int64(book.importedAt.timeIntervalSince1970 * 1000) {
                        state.updates.append(ChapterUpdate(bookID: book.id, chapter: chapter, foundAt: Date()))
                        additions.append(chapter)
                    }
                }
                if UserDefaults.standard.bool(forKey: "downloads.newChapters"), shouldDownload(book) {
                    for chapter in additions.reversed() where book.chapters?.first(where: { $0.url == chapter.url })?.completed != true {
                        downloads.enqueue(source: source, manga: result.manga, chapter: chapter, userInitiated: false)
                    }
                }
                if UserDefaults.standard.integer(forKey: "downloads.removedPolicy") == 2, let old {
                    let remaining = Set(result.chapters.map(\.url))
                    for chapter in old where !remaining.contains(chapter.url) { downloads.deleteIfAllowed(bookID: book.id, chapterURL: chapter.url) }
                }
                state.chapters[book.id] = result.chapters
                library.saveDetails(result, source: source)
            } catch { errors.append(book.title + "：" + error.localizedDescription) }
        }
        state.updates.removeAll { row in !library.books.contains { $0.id == row.bookID && $0.inLibrary != false } }
        state.checkedAt = Date()
        do { try JSONEncoder().encode(state).write(to: file, options: .atomic) }
        catch { errors.append(error.localizedDescription) }
    }
    private func shouldUpdate(_ book: ComicBook) -> Bool {
        let defaults = UserDefaults.standard, categories = book.categories ?? []
        let included = defaults.stringArray(forKey: "library.updateCategories") ?? []
        let excluded = defaults.stringArray(forKey: "library.updateExcludedCategories") ?? []
        if !included.isEmpty && !categories.contains(where: included.contains) { return false }
        if categories.contains(where: excluded.contains) { return false }
        if defaults.bool(forKey: "library.skipCompleted") && book.mangaInfo?.status == 2 { return false }
        if defaults.bool(forKey: "library.skipUnread") && book.lastRead == nil { return false }
        return true
    }
    private func shouldDownload(_ book: ComicBook) -> Bool {
        let defaults = UserDefaults.standard, categories = book.categories ?? []
        let included = defaults.stringArray(forKey: "downloads.newCategories") ?? []
        let excluded = defaults.stringArray(forKey: "downloads.newExcludedCategories") ?? []
        return (included.isEmpty || categories.contains(where: included.contains)) && !categories.contains(where: excluded.contains)
    }
}

struct RecentsView: View {
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @EnvironmentObject private var activity: LibraryActivity
    @EnvironmentObject private var downloads: DownloadStore
    @State private var tab = "all"
    @State private var query = ""
    @State private var reading: ComicBook?
    @State private var details: ComicBook?
    @State private var showingMore = false
    private struct Entry: Identifiable {
        var id: String { book.id + "\n" + (chapter?.url ?? "local") }
        let book: ComicBook
        let chapter: ChapterProgress?
        let date: Date
    }
    private var history: [Entry] {
        library.books.flatMap { book -> [Entry] in
            guard let last = book.lastRead else { return [] }
            let rows = (book.chapters ?? []).compactMap { chapter -> Entry? in
                guard let date = chapter.lastRead ?? (chapter.url == book.origin?.chapterURL ? last : nil) else { return nil }
                return Entry(book: book, chapter: chapter, date: date)
            }
            return rows.isEmpty ? [Entry(book: book, chapter: nil, date: last)] : rows
        }.filter { matches($0.book) }.sorted { $0.date > $1.date }
    }
    private func matches(_ book: ComicBook) -> Bool { query.isEmpty || book.title.localizedCaseInsensitiveContains(query) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("最近", selection: $tab) { Text("全部").tag("all"); Text("更新").tag("updates"); Text("历史").tag("history") }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
                List {
                    if activity.busy { ProgressView("正在检查书架更新…") }
                    if tab != "history" {
                        Section("更新") {
                            ForEach(activity.updates) { update in
                                if let book = library.books.first(where: { $0.id == update.bookID }), matches(book) {
                                    Button { details = book } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(book.title).foregroundStyle(.primary)
                                            Text(update.chapter.name).font(.subheadline).foregroundStyle(.secondary)
                                            Text(update.foundAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            if activity.updates.isEmpty { Text("暂无新章节").foregroundStyle(.secondary) }
                            if let date = activity.checkedAt { Text("上次检查：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
                            ForEach(activity.errors, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                        }
                    }
                    if tab != "updates" {
                        Section("历史") {
                            ForEach(history) { entry in
                                Button { open(entry) } label: {
                                    HStack {
                                        BookCover(book: entry.book).frame(width: 44, height: 66)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.book.title).foregroundStyle(.primary)
                                            if let chapter = entry.chapter { Text("\(chapter.title) · 第 \(chapter.lastPage + 1) 页").font(.subheadline).foregroundStyle(.secondary) }
                                            Text(entry.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            if history.isEmpty { Text("暂无阅读历史").foregroundStyle(.secondary) }
                        }
                    }
                }.refreshable { await activity.refresh(library: library, extensions: extensions, downloads: downloads) }
            }
            .navigationTitle("最近").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索更新与历史")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("更多", systemImage: "line.3.horizontal") { showingMore = true } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更新与历史", systemImage: "ellipsis") {
                        Button("检查更新", systemImage: "arrow.clockwise") { Task { await activity.refresh(library: library, extensions: extensions, downloads: downloads) } }.disabled(activity.busy)
                        NavigationLink("书架更新设置") { LibraryUpdateSettingsView() }
                        Button("清除阅读历史", role: .destructive) { clearingHistory = true }
                    }
                }
            }
            .sheet(isPresented: $showingMore) { MoreView() }
            .alert("清除阅读历史？", isPresented: $clearingHistory) {
                Button("清除", role: .destructive) { library.clearHistory() }; Button("取消", role: .cancel) {}
            } message: { Text("阅读进度和书签会保留。") }
            .navigationDestination(isPresented: Binding(get: { details != nil }, set: { if !$0 { details = nil } })) {
                if let book = details { BookDetailsView(book: book) }
            }
            .fullScreenCover(item: $reading) { book in ReaderView(book: book, directory: library.directory(for: book)).environmentObject(library) }
        }
    }
    @State private var clearingHistory = false
    private func open(_ entry: Entry) {
        var book = entry.book
        if let chapter = entry.chapter {
            let directory = library.chapterDirectory(bookID: book.id, chapterURL: chapter.url)
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("chapter.json")),
                  let cached = try? JSONDecoder().decode(CachedChapter.self, from: data) else { details = book; return }
            if let resumed = library.openChapter(cached.chapter, pages: cached.pageCount, bookID: book.id) { book = resumed }
        }
        if library.isAvailable(book) { reading = book } else { details = book }
    }
}
