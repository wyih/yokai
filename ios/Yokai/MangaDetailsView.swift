import SwiftUI

// Mirrors MangaDetailsController: cover/info, library/WebView actions, summary,
// a separate start/continue button, then the sortable chapter list.
struct BookDetailsView: View {
    let book: ComicBook
    @EnvironmentObject private var extensions: ExtensionStore
    var body: some View {
        Group {
            if let origin = book.origin,
               let source = extensions.sources.first(where: { $0.id == origin.sourceID }) {
                SourceDetailsView(source: source, manga: SourceManga(url: origin.mangaURL, title: book.title,
                                                                   thumbnail: origin.thumbnail, memo: origin.mangaMemo))
            } else {
                StoredBookDetailsView(book: book)
            }
        }
        .task { await extensions.start() }
    }
}

struct ChapterDisplayOptions: Codable, Equatable {
    var sort = "source"
    var descending = true
    var read = "all"
    var downloaded = "all"
    var bookmarked = "all"
    var scanlatorFilters: [String: String]? = nil

    func acceptsScanlator(_ chapter: SourceChapter) -> Bool {
        let filters = scanlatorFilters ?? [:]
        let included = filters.filter { $0.value == "yes" }.map(\.key)
        return filters[chapter.scanlatorKey] != "no" && (included.isEmpty || included.contains(chapter.scanlatorKey))
    }
}

struct SourceDetailsView: View {
    let source: MangaSource
    let manga: SourceManga
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var downloads: DownloadStore
    @State private var details: SourceDetails?
    @State private var busy = false
    @State private var error: String?
    @State private var requestedDownload: String?
    @State private var progress: String?
    @State private var reading: ComicBook?
    @State private var webView = false
    @State private var settings = false
    @State private var showFilters = false
    @State private var showRefreshSettings = false
    @State private var expandedDescription = false
    @State private var selectingChapters = false
    @State private var chosenChapters = Set<String>()
    @State private var query = ""
    @State private var globalSearchQuery: String?
    @State private var options = ChapterDisplayOptions()
    @State private var mangaAddress: URL?
    @State private var choosingCategory = false
    @State private var removedDownloads: [SourceChapter] = []
    @State private var progressByURL: [String: ChapterProgress] = [:]

    private let bookID: String
    init(source: MangaSource, manga: SourceManga) {
        self.source = source; self.manga = manga
        bookID = ComicLibrary.hash(source.id + "\n" + manga.url)
    }
    private var currentBook: ComicBook? { library.books.first { $0.id == bookID } }
    private var inLibrary: Bool { currentBook != nil && currentBook?.inLibrary != false }
    private var information: SourceManga { details?.manga ?? manga }
    private var allChapters: [SourceChapter] { details?.chapters ?? [] }
    private var displayedChapters: [SourceChapter] {
        sortedChapters(descending: options.descending).filter { chapter in
            (query.isEmpty || chapter.name.localizedCaseInsensitiveContains(query))
                && (options.read == "all" || accepts(options.read, value: chapterProgress(chapter)?.completed ?? false))
                && (options.downloaded == "all" || accepts(options.downloaded, value: isDownloaded(chapter)))
                && (options.bookmarked == "all" || accepts(options.bookmarked, value: isBookmarked(chapter)))
                && options.acceptsScanlator(chapter)
        }
    }
    private var selectedChapters: [SourceChapter] { allChapters.filter { chosenChapters.contains($0.url) } }
    private var nextUnread: SourceChapter? {
        sortedChapters(descending: false).first { options.acceptsScanlator($0) && chapterProgress($0)?.completed != true }
    }
    private var displayKey: String { "chapters.display." + bookID }
    private var fetchedKey: String { "cache.details.lastFetched." + bookID }
    private var scanlators: [String] {
        Set(allChapters.map(\.scanlatorKey) + Array((options.scanlatorFilters ?? [:]).keys)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                SourceCoverRecoveryView(source: source)
                HStack(spacing: 16) {
                    Button {
                        let book = ensureBook()
                        let adding = !inLibrary
                        library.setFavorite(!inLibrary, bookID: book.id)
                        if adding, YokaiStorage.defaults.string(forKey: "library.defaultCategory") == "ask" { choosingCategory = true }
                    } label: {
                        Label(inLibrary ? "已在书架" : "加入书架",
                              systemImage: inLibrary ? "heart.fill" : "heart")
                    }.buttonStyle(.bordered)
                    Button("打开 WebView", systemImage: "globe") { webView = true }
                        .labelStyle(.iconOnly)
                    if let url = mangaAddress {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("分享漫画")
                    }
                    Spacer()
                }.listRowSeparator(.hidden)
                if let description = information.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("简介").font(.headline)
                        Text(description).font(.subheadline).lineLimit(expandedDescription ? nil : 3).textSelection(.enabled)
                        Button(expandedDescription ? "收起" : "更多") { expandedDescription.toggle() }
                    }.listRowSeparator(.hidden)
                }
                if let genre = information.genre, !genre.isEmpty {
                    MangaGenreView(genre: genre) { globalSearchQuery = $0 }.listRowSeparator(.hidden)
                }
                if !allChapters.isEmpty {
                    Button {
                        if let chapter = nextUnread { read(chapter) }
                    } label: {
                        Label(readButtonTitle, systemImage: "play.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(nextUnread == nil)
                        .listRowSeparator(.hidden)
                }
            }
            if busy { ProgressView("正在更新漫画信息与章节…") }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                    if !allChapters.isEmpty { Text("下面保留本地保存的章节，可继续阅读已缓存章节。").font(.footnote).foregroundStyle(.secondary) }
                    HStack {
                        Button("重试") { Task { await load() } }
                        Button("打开 WebView") { webView = true }
                        Button("图源设置") { settings = true }
                    }
                }
            }
            if let progress { Text(progress).font(.footnote).foregroundStyle(.secondary) }
            Section {
                ForEach(displayedChapters) { chapter in chapterRow(chapter) }
                if !busy && displayedChapters.isEmpty {
                    Text(allChapters.isEmpty ? "暂无章节" : "没有符合筛选条件的章节").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("\(allChapters.count) 章").font(.headline).foregroundStyle(.primary)
                    Spacer()
                    Button("排序与筛选", systemImage: "line.3.horizontal.decrease") { showFilters = true }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("chapterFiltersButton")
                }.textCase(nil)
            }
        }
        .listStyle(.plain)
        .navigationTitle(currentBook?.title ?? information.title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .searchable(text: $query, prompt: "搜索章节")
        .submitScope()
        .navigationDestination(item: $globalSearchQuery) { GlobalSearchView(initialQuery: $0) }
        .refreshable { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("下载", systemImage: "arrow.down.circle") {
                    Button("下载下一章") { if let chapter = nextUnread { enqueue(chapter) } }
                    Button("下载接下来 5 个未读章节") { for chapter in unreadChapters.prefix(5) { enqueue(chapter) } }
                    Button("下载全部未读章节") { for chapter in unreadChapters { enqueue(chapter) } }
                    Button("下载全部章节") { for chapter in allChapters { enqueue(chapter) } }
                }.disabled(allChapters.isEmpty)
                Menu("章节操作", systemImage: "ellipsis") {
                    Button(selectingChapters ? "完成选择" : "选择章节") { selectingChapters.toggle() }
                    if selectingChapters {
                        Button("全选当前列表") { chosenChapters = Set(displayedChapters.map(\.url)) }
                        Button("取消全选") { chosenChapters = [] }
                        Button("下载所选章节") { for chapter in selectedChapters { enqueue(chapter) } }
                        Button("标记所选为已读") { mark(selectedChapters, completed: true) }
                        Button("标记所选为未读") { mark(selectedChapters, completed: false) }
                    }
                    Button("全部标记为已读") { mark(allChapters, completed: true) }
                    Button("全部标记为未读") { mark(allChapters, completed: false) }
                    Button("刷新详情", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(busy).accessibilityIdentifier("detailsRefreshNow")
                    Button("详情刷新设置", systemImage: "clock.arrow.circlepath") { showRefreshSettings = true }
                        .accessibilityIdentifier("detailsRefreshSettings")
                    Button("图源设置") { settings = true }
                }.accessibilityIdentifier("chapterActionsMenu")
            }
        }
        .task {
            if let data = YokaiStorage.defaults.data(forKey: displayKey),
               let saved = try? JSONDecoder().decode(ChapterDisplayOptions.self, from: data) { options = saved }
            if let book = currentBook {
                details = library.cachedDetails(for: book)
                rebuildProgress()
                await library.refreshDownloadedChapters(bookIDs: [book.id])
            }
            await updateWebAddress()
            if SourceDetailsRefreshPolicy.shouldRefresh(cached: details, fetchedAt: YokaiStorage.defaults.object(forKey: fetchedKey) as? Date) {
                await load()
            }
        }
        .onChange(of: options) { _, value in
            if let data = try? JSONEncoder().encode(value) { YokaiStorage.defaults.set(data, forKey: displayKey) }
        }
        .onChange(of: library.changeCount) { _, _ in rebuildProgress() }
        .sheet(isPresented: $showFilters) { chapterFilters }
        .sheet(isPresented: $showRefreshSettings) {
            NavigationStack {
                SourceDetailsRefreshSettingsView()
                    .toolbar { Button("完成") { showRefreshSettings = false } }
            }
        }
        .alert("图源已移除 \(removedDownloads.count) 个已下载章节", isPresented: Binding(get: { !removedDownloads.isEmpty }, set: { if !$0 { removedDownloads = [] } })) {
            Button("保留下载", role: .cancel) { removedDownloads = [] }
            Button("删除下载", role: .destructive) { for chapter in removedDownloads { downloads.deleteIfAllowed(bookID: bookID, chapterURL: chapter.url) }; removedDownloads = [] }
        } message: { Text("阅读进度和书签会保留。") }
        .sheet(isPresented: $choosingCategory) { CategoryAssignmentView(bookIDs: [bookID]) }
        .sheet(isPresented: $webView, onDismiss: { Task { await load() } }) { SourceLoginView(source: source, manga: information) }
        .sheet(isPresented: $settings, onDismiss: { Task { await updateWebAddress(); await load() } }) { SourcePreferencesView(source: source) }
        .onReceive(downloads.$jobs) { jobs in
            guard let id = requestedDownload, let job = jobs.first(where: { $0.id == id }) else { return }
            if job.total > 0 && job.completed > 0 {
                requestedDownload = nil; progress = nil
                let book = ensureBook()
                reading = library.openChapter(job.chapter, pages: job.total, bookID: book.id)
            } else if job.state == .failed { error = job.error; requestedDownload = nil; progress = nil }
            else { progress = "正在加载 \(job.completed) / \(job.total) 页" }
        }
        .fullScreenCover(item: $reading) { book in ReaderView(book: book, directory: library.directory(for: book)) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let book = currentBook {
                    BookCover(book: book)
                } else { MangaCover(source: source, url: information.thumbnail) }
            }.frame(width: 100)
            VStack(alignment: .leading, spacing: 6) {
                MangaMetadataView(title: currentBook?.title ?? information.title, author: information.author, artist: information.artist) { globalSearchQuery = $0 }
                if let status = information.status, let title = statusTitle(status) { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                Text(source.name ?? source.package).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 12)
    }

    private func chapterRow(_ chapter: SourceChapter) -> some View {
        let state = chapterProgress(chapter)
        let job = downloads.jobs.first { $0.sourceID == source.id && $0.manga.url == manga.url && $0.chapter.url == chapter.url }
        return HStack(spacing: 12) {
            if selectingChapters {
                Button { toggleSelection(chapter) } label: {
                    Image(systemName: chosenChapters.contains(chapter.url) ? "checkmark.circle.fill" : "circle")
                }
            }
            Button {
                if selectingChapters { toggleSelection(chapter) } else { read(chapter) }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        if isBookmarked(chapter) { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(Color.accentColor) }
                        Text(chapter.name).lineLimit(2)
                    }.foregroundStyle(state?.completed == true ? .secondary : .primary)
                    HStack(spacing: 5) {
                        if !chapter.scanlatorKey.isEmpty { Text(chapter.scanlatorKey) }
                        if chapter.uploaded > 0 { Text(Date(timeIntervalSince1970: Double(chapter.uploaded) / 1000), style: .date) }
                        if state?.completed == true { Text("已读") }
                        else if let state, state.lastPage > 0 { Text("第 \(state.lastPage + 1) 页") }
                        if let job, job.state == .downloading || job.state == .queued { Text("\(job.completed) / \(job.total)") }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            if isDownloaded(chapter) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).accessibilityLabel("已下载")
            } else {
                Button("下载章节", systemImage: "arrow.down.circle") { enqueue(chapter) }.labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless).padding(.vertical, 5)
        .accessibilityIdentifier("chapter-" + chapter.url)
        .contextMenu {
            Button(isBookmarked(chapter) ? "取消章节书签" : "添加章节书签", systemImage: "bookmark") {
                let book = ensureBook(); library.bookmarkChapter(chapter, bookID: book.id)
            }
            Button("标记为已读") { mark([chapter], completed: true) }
            Button("标记为未读") { mark([chapter], completed: false) }
            Button("下载章节") { enqueue(chapter) }
            Button("选择章节") { selectingChapters = true; chosenChapters.insert(chapter.url) }
        }
        .swipeActions(edge: .leading) {
            Button(isBookmarked(chapter) ? "取消书签" : "书签", systemImage: "bookmark") {
                let book = ensureBook(); library.bookmarkChapter(chapter, bookID: book.id)
            }.tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(state?.completed == true ? "未读" : "已读", systemImage: "checkmark") {
                mark([chapter], completed: state?.completed != true)
            }.tint(.green)
        }
    }

    private var chapterFilters: some View {
        NavigationStack {
            Form {
                Section("排序") {
                    Picker("排序方式", selection: $options.sort) {
                        Text("图源顺序").tag("source"); Text("章节编号").tag("number"); Text("更新时间").tag("uploaded")
                    }
                    Toggle("降序", isOn: $options.descending)
                }
                Section("筛选") {
                    filterPicker("已读", value: $options.read)
                    filterPicker("已下载", value: $options.downloaded)
                    filterPicker("有书签", value: $options.bookmarked)
                    Button("重置") { options = ChapterDisplayOptions() }.accessibilityIdentifier("chapterFiltersReset")
                }
                if !scanlators.isEmpty {
                    Section {
                        ForEach(scanlators, id: \.self) { scanlator in
                            Picker(scanlator.isEmpty ? "未标注汉化组" : scanlator, selection: Binding(
                                get: { options.scanlatorFilters?[scanlator] ?? "all" },
                                set: { value in
                                    var filters = options.scanlatorFilters ?? [:]
                                    filters[scanlator] = value == "all" ? nil : value
                                    options.scanlatorFilters = filters.isEmpty ? nil : filters
                                }
                            )) {
                                Text("不限").tag("all"); Text("包含").tag("yes"); Text("排除").tag("no")
                            }.accessibilityIdentifier("scanlator-" + scanlator)
                        }
                        Button("清除汉化组筛选") { options.scanlatorFilters = nil }.accessibilityIdentifier("scanlatorFiltersReset")
                    } header: { Text("汉化组") } footer: {
                        Text("可包含多个汉化组；选择包含后，仅显示这些组的章节。排除会隐藏对应组。")
                    }
                }
            }.navigationTitle("排序与筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { showFilters = false } }
        }.presentationDetents([.medium, .large])
    }
    private func filterPicker(_ title: String, value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text("全部").tag("all"); Text("仅显示").tag("yes"); Text("排除").tag("no")
        }
    }
    private func accepts(_ filter: String, value: Bool) -> Bool { filter == "all" || (filter == "yes" ? value : !value) }
    private func chapterProgress(_ chapter: SourceChapter) -> ChapterProgress? {
        progressByURL[chapter.url]
    }
    private func rebuildProgress() {
        guard let book = currentBook else { progressByURL = [:]; return }
        var values = Dictionary((book.chapters ?? []).map { ($0.url, $0) }, uniquingKeysWith: { _, newest in newest })
        if let url = book.origin?.chapterURL, values[url] == nil {
            values[url] = ChapterProgress(url: url, title: book.origin?.chapterTitle ?? "章节", pageCount: book.pageCount,
                lastPage: book.lastPage, completed: book.lastPage == book.pageCount - 1, lastRead: book.lastRead)
        }
        if progressByURL != values { progressByURL = values }
    }
    private func isBookmarked(_ chapter: SourceChapter) -> Bool {
        chapterProgress(chapter)?.bookmarked == true
    }
    private func isDownloaded(_ chapter: SourceChapter) -> Bool {
        library.isChapterDownloaded(bookID: bookID, chapterURL: chapter.url)
    }
    private func sortedChapters(descending: Bool) -> [SourceChapter] {
        if options.sort == "source" { return descending ? allChapters : Array(allChapters.reversed()) }
        return allChapters.enumerated().sorted {
            if options.sort == "uploaded", $0.element.uploaded != $1.element.uploaded {
                return descending ? $0.element.uploaded > $1.element.uploaded : $0.element.uploaded < $1.element.uploaded
            }
            if options.sort == "number", $0.element.number != $1.element.number {
                return descending ? $0.element.number > $1.element.number : $0.element.number < $1.element.number
            }
            return descending ? $0.offset < $1.offset : $0.offset > $1.offset
        }.map(\.element)
    }
    private var unreadChapters: [SourceChapter] { sortedChapters(descending: false).filter { options.acceptsScanlator($0) && chapterProgress($0)?.completed != true && !isDownloaded($0) } }
    private var readButtonTitle: String {
        guard let chapter = nextUnread else { return "当前筛选下没有未读章节" }
        return (chapterProgress(chapter)?.lastPage ?? 0) > 0 ? "继续阅读 · \(chapter.name)" : "开始阅读 · \(chapter.name)"
    }
    private func updateWebAddress() async {
        let info = try? await SourceEngine.call("webViewInfo",
                                               ["source": source.id, "manga": SourceEngine.object(information)], as: SourceWebInfo.self)
        mangaAddress = info.flatMap { URL(string: $0.url) }
    }
    private func statusTitle(_ value: Int) -> String? {
        switch value { case 1: "连载中"; case 2: "已完结"; case 3: "已授权"; case 4: "已停刊"; case 5: "已停更"; case 6: "休刊中"; default: nil }
    }
    @discardableResult private func ensureBook() -> ComicBook {
        let book = library.addOnline(information, source: source, favorite: false)
        if let details, library.cachedDetails(for: book) != details { library.saveDetails(details, source: source) }
        return library.books.first { $0.id == book.id } ?? book
    }
    private func toggleSelection(_ chapter: SourceChapter) {
        if !chosenChapters.insert(chapter.url).inserted { chosenChapters.remove(chapter.url) }
    }
    private func mark(_ chapters: [SourceChapter], completed: Bool) {
        let book = ensureBook(); library.markChapters(chapters, bookID: book.id, completed: completed)
        if completed && YokaiStorage.defaults.bool(forKey: "downloads.removeAfterMarked") {
            for chapter in chapters { downloads.deleteIfAllowed(bookID: book.id, chapterURL: chapter.url) }
        }
        chosenChapters = []; selectingChapters = false
    }
    private func enqueue(_ chapter: SourceChapter) {
        _ = ensureBook()
        downloads.enqueue(source: source, manga: information, chapter: chapter)
    }
    private func load() async {
        guard !busy else { return }; busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await SourceEngine.call("details", ["source": source.id, "manga": SourceEngine.object(information)], as: SourceDetails.self)
            let remaining = Set(result.chapters.map(\.url))
            let removed = allChapters.filter { !remaining.contains($0.url) && isDownloaded($0) }
            switch YokaiStorage.defaults.integer(forKey: "downloads.removedPolicy") {
            case 0: removedDownloads = removed
            case 2: for chapter in removed { downloads.deleteIfAllowed(bookID: bookID, chapterURL: chapter.url) }
            default: break
            }
            details = result
            _ = library.addOnline(result.manga, source: source, favorite: false)
            library.saveDetails(result, source: source)
            if let book = currentBook, library.cachedDetails(for: book) == result {
                YokaiStorage.defaults.set(Date(), forKey: fetchedKey)
            }
            if let book = currentBook { await library.cacheSourceCover(book, source: source) }
        } catch { self.error = error.localizedDescription }
    }
    private func read(_ chapter: SourceChapter) {
        let book = ensureBook()
        let directory = library.chapterDirectory(bookID: book.id, chapterURL: chapter.url)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("chapter.json")),
           let cached = try? JSONDecoder().decode(CachedChapter.self, from: data) {
            reading = library.openChapter(cached.chapter, pages: cached.pageCount, bookID: book.id)
        } else {
            requestedDownload = downloads.enqueue(source: source, manga: information, chapter: chapter, forReading: true)
            error = nil; progress = "正在加载章节…"
            if let job = downloads.jobs.first(where: { $0.id == requestedDownload && $0.total > 0 && $0.completed > 0 }) {
                reading = library.openChapter(job.chapter, pages: job.total, bookID: book.id); requestedDownload = nil; progress = nil
            }
        }
    }
}

private struct StoredBookDetailsView: View {
    let book: ComicBook
    @EnvironmentObject private var library: ComicLibrary
    @State private var reading: ComicBook?
    @State private var globalSearchQuery: String?
    private var current: ComicBook { library.books.first { $0.id == book.id } ?? book }
    private var information: SourceManga? { library.cachedDetails(for: current)?.manga }
    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    BookCover(book: current).frame(width: 100)
                    VStack(alignment: .leading, spacing: 6) {
                        MangaMetadataView(title: current.title, author: information?.author ?? current.mangaInfo?.author,
                                          artist: information?.artist ?? current.mangaInfo?.artist) { globalSearchQuery = $0 }
                        Text(current.origin == nil ? "本地图源" : "图源插件尚未安装").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.listRowSeparator(.hidden)
                if let description = information?.description, !description.isEmpty {
                    Text(description).font(.subheadline).textSelection(.enabled)
                }
                if let genre = information?.genre ?? current.mangaInfo?.genre, !genre.isEmpty {
                    MangaGenreView(genre: genre) { globalSearchQuery = $0 }
                }
                if library.isAvailable(current) {
                    Button(current.lastPage > 0 ? "继续阅读" : "开始阅读", systemImage: "play.fill") { reading = current }
                        .buttonStyle(.borderedProminent)
                }
            }
            Section("章节") {
                if current.origin == nil {
                    Button { if library.isAvailable(current) { reading = current } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(current.title)
                            Text("\(current.pageCount) 页 · 已读至第 \(current.lastPage + 1) 页").font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(!library.isAvailable(current))
                } else {
                    ForEach(library.cachedDetails(for: current)?.chapters ?? []) { chapter in
                        Button(chapter.name) { open(chapter) }
                            .disabled(!library.isChapterDownloaded(bookID: current.id, chapterURL: chapter.url))
                    }
                    Text("请在浏览页安装对应图源插件。已缓存的章节仍可阅读。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.listStyle(.plain)
            .navigationTitle(current.title).navigationBarTitleDisplayMode(.inline).toolbar(.hidden, for: .tabBar)
            .navigationDestination(item: $globalSearchQuery) { GlobalSearchView(initialQuery: $0) }
            .task { await library.refreshDownloadedChapters(bookIDs: [current.id]) }
            .fullScreenCover(item: $reading) { book in ReaderView(book: book, directory: library.directory(for: book)) }
    }
    private func open(_ chapter: SourceChapter) {
        let directory = library.chapterDirectory(bookID: current.id, chapterURL: chapter.url)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("chapter.json")),
              let cached = try? JSONDecoder().decode(CachedChapter.self, from: data) else { return }
        reading = library.openChapter(cached.chapter, pages: cached.pageCount, bookID: current.id)
    }
}

enum SourceDetailsRefreshPolicy {
    static let enabledKey = "sources.details.autoRefresh"
    static let intervalKey = "sources.details.refreshInterval"
    static let defaultInterval: Double = 900

    static func shouldRefresh(cached: SourceDetails?, fetchedAt: Date?, defaults: UserDefaults = YokaiStorage.defaults,
                              now: Date = Date()) -> Bool {
        guard let cached, !cached.chapters.isEmpty else { return true }
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        guard enabled else { return false }
        guard let fetchedAt else { return true }
        let interval = defaults.object(forKey: intervalKey) == nil ? defaultInterval : max(0, defaults.double(forKey: intervalKey))
        let age = now.timeIntervalSince(fetchedAt)
        return age < 0 || age >= interval
    }
}

struct SourceDetailsRefreshSettingsView: View {
    @AppStorage(SourceDetailsRefreshPolicy.enabledKey, store: YokaiStorage.defaults) private var enabled = true
    @AppStorage(SourceDetailsRefreshPolicy.intervalKey, store: YokaiStorage.defaults) private var interval = SourceDetailsRefreshPolicy.defaultInterval

    var body: some View {
        Form {
            Section {
                Toggle("进入详情时自动刷新", isOn: $enabled).accessibilityIdentifier("detailsAutoRefresh")
                Picker("最短刷新间隔", selection: $interval) {
                    Text("每次进入").tag(0.0)
                    Text("5 分钟").tag(300.0)
                    Text("15 分钟").tag(900.0)
                    Text("1 小时").tag(3600.0)
                    Text("6 小时").tag(21600.0)
                    Text("1 天").tag(86400.0)
                }.disabled(!enabled).accessibilityIdentifier("detailsRefreshInterval")
            } footer: {
                Text("按每本漫画上次成功刷新详情的时间计算。没有缓存章节时仍会加载；下拉刷新或菜单中的“刷新详情”不受此设置限制。")
            }
        }.navigationTitle("详情刷新").navigationBarTitleDisplayMode(.inline)
    }
}

enum MangaGenres {
    static func tags(_ genre: String) -> [String] {
        var seen = Set<String>()
        return genre.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private struct MangaGenreView: View {
    let genre: String
    let search: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MangaGenres.tags(genre), id: \.self) { tag in
                    Menu {
                        Button("复制标签", systemImage: "doc.on.doc") { UIPasteboard.general.string = tag }
                        Button("全局搜索", systemImage: "magnifyingglass") { search(tag) }
                    } label: {
                        Text(tag).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    } primaryAction: {
                        search(tag)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("manga-genre-" + tag)
                    .accessibilityLabel("标签：" + tag)
                    .accessibilityHint("点按全局搜索，长按复制标签")
                }
            }
        }
    }
}

private struct MangaMetadataView: View {
    let title: String
    let author: String?
    let artist: String?
    let search: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            value(title, field: "title", label: "标题")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(.primary).lineLimit(4)
            if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                value(author, field: "author", label: "作者").font(.subheadline).foregroundStyle(Color.accentColor)
            }
            if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, artist != author {
                value(artist, field: "artist", label: "画师").font(.subheadline).foregroundStyle(Color.accentColor)
            }
        }
    }

    private func value(_ text: String, field: String, label: String) -> some View {
        Menu {
            Button("复制" + label, systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            Button("全局搜索", systemImage: "magnifyingglass") { search(text) }
        } label: {
            Text(text).multilineTextAlignment(.leading)
        } primaryAction: {
            search(text)
        }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manga-" + field)
            .accessibilityLabel(label + "：" + text)
            .accessibilityHint("点按全局搜索，长按复制" + label)
    }
}
