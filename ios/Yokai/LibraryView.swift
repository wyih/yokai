import SwiftUI
import UniformTypeIdentifiers

struct LibraryDisplayOptions: Codable, Equatable {
    var sort = "recent"
    var descending = true
    var grouping = "category"
    var display = "grid"
    var columns = 3
    var downloaded = "all"
    var unread = "all"
    var started = "all"
    var completed = "all"
    var bookmarked = "all"
    var badges = true
    var showSource = false
    var showCount = true
    static func load() -> Self {
        UserDefaults.standard.data(forKey: "library.display").flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "library.display") } }
}

struct LibraryView: View {
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @EnvironmentObject private var downloads: DownloadStore
    @State private var query = ""
    @State private var importing = false
    @State private var selectedBook: ComicBook?
    @State private var showingMore = false
    @State private var showingOptions = false
    @State private var options = LibraryDisplayOptions.load()
    @State private var category = "all"
    @State private var selecting = false
    @State private var chosen = Set<String>()
    @State private var categorySelection = false
    @State private var removing = false
    @State private var renaming: ComicBook?
    @State private var title = ""
    @State private var coverBook: ComicBook?
    @State private var importingCover = false
    @State private var busy = false
    @State private var metrics: [String: ShelfBookMetrics] = [:]
    private var shelf: [ComicBook] { library.books.filter { $0.inLibrary != false } }
    private var books: [ComicBook] {
        let manual = UserDefaults.standard.stringArray(forKey: "library.manualOrder") ?? []
        return shelf.filter { book in
            let text = [book.title, book.mangaInfo?.author, book.mangaInfo?.artist, book.mangaInfo?.genre].compactMap { $0 }.joined(separator: " ")
            let m = metrics[book.id] ?? ShelfBookMetrics()
            return (query.isEmpty || text.localizedCaseInsensitiveContains(query))
                && (category == "all" || (category == "default" ? (book.categories ?? []).isEmpty : (book.categories ?? []).contains(category)))
                && accepts(options.downloaded, m.downloaded > 0)
                && accepts(options.unread, book.origin == nil ? book.lastPage < book.pageCount - 1 : m.unread > 0)
                && accepts(options.started, book.lastRead != nil || (book.chapters ?? []).contains { $0.completed || $0.lastPage > 0 })
                && accepts(options.completed, book.mangaInfo?.status == 2)
                && accepts(options.bookmarked, book.bookmarks.contains { !$0.deleted } || (book.chapters ?? []).contains { $0.bookmarked == true })
        }.sorted { a, b in
            let x = metrics[a.id] ?? ShelfBookMetrics(), y = metrics[b.id] ?? ShelfBookMetrics()
            var order: ComparisonResult
            switch options.sort {
            case "title": order = a.title.localizedStandardCompare(b.title)
            case "unread": order = compare(x.unread, y.unread)
            case "chapters": order = compare(x.chapters, y.chapters)
            case "latest": order = compare(x.latest, y.latest)
            case "added": order = compare(a.importedAt, b.importedAt)
            case "fetched": order = compare(a.mangaInfo?.fetchedAt ?? .distantPast, b.mangaInfo?.fetchedAt ?? .distantPast)
            case "manual": return (manual.firstIndex(of: a.id) ?? Int.max) < (manual.firstIndex(of: b.id) ?? Int.max)
            case "random": order = ComicLibrary.hash(a.id + Date().formatted(.iso8601.year().month().day())).compare(ComicLibrary.hash(b.id + Date().formatted(.iso8601.year().month().day())))
            default: order = compare(a.lastRead ?? .distantPast, b.lastRead ?? .distantPast)
            }
            if order == .orderedSame { return a.id < b.id }
            return options.descending ? order == .orderedDescending : order == .orderedAscending
        }
    }
    private var groups: [(String, [ComicBook])] {
        guard options.grouping != "category" && options.grouping != "none" else { return [("", books)] }
        let grouped = Dictionary(grouping: books) { book in
            switch options.grouping {
            case "source": return extensions.sources.first { $0.id == book.origin?.sourceID }?.name ?? (book.origin == nil ? "本地" : "未安装的图源")
            case "status": return mangaStatus(book.mangaInfo?.status)
            case "author": return book.mangaInfo?.author ?? "未知作者"
            default: return ""
            }
        }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if options.grouping == "category" {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            categoryButton("全部", id: "all")
                            categoryButton("默认", id: "default")
                            ForEach(library.categoryNames, id: \.self) { categoryButton($0, id: $0) }
                        }.padding(.horizontal).padding(.vertical, 8)
                    }
                }
                if shelf.isEmpty {
                    ContentUnavailableView("书架为空", systemImage: "books.vertical", description: Text("在浏览中加入漫画，或导入本地漫画。"))
                } else if books.isEmpty { ContentUnavailableView("没有符合条件的漫画", systemImage: "line.3.horizontal.decrease") }
                else if options.display == "list" || options.sort == "manual" {
                    List {
                        ForEach(groups, id: \.0) { group in
                            Section(group.0) {
                                ForEach(group.1) { book in row(book) }
                                    .onMove { from, to in
                                        var order = books.map(\.id); order.move(fromOffsets: from, toOffset: to)
                                        UserDefaults.standard.set(order, forKey: "library.manualOrder"); rebuildMetrics()
                                    }
                            }
                        }
                    }.listStyle(.plain)
                } else {
                    ScrollView {
                        ForEach(groups, id: \.0) { group in
                            if !group.0.isEmpty { Text(group.0).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, min(6, options.columns))), spacing: 14) {
                                ForEach(group.1) { book in tile(book) }
                            }.padding(.horizontal).padding(.bottom)
                        }
                    }
                }
            }
            .navigationTitle(selecting ? "已选择 \(chosen.count) 项" : "书架").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索名称、作者或标签")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selecting { Button("完成") { selecting = false; chosen = [] } }
                    else { Button("更多", systemImage: "line.3.horizontal") { showingMore = true } }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selecting {
                        Menu("批量操作", systemImage: "ellipsis") {
                            Button("全选") { chosen = Set(books.map(\.id)) }
                            Button("反选") { chosen = Set(books.map(\.id)).subtracting(chosen) }
                            Button("设置分类") { categorySelection = true }.disabled(chosen.isEmpty)
                            Button("标记已读") { Task { await bulkRead(true) } }.disabled(chosen.isEmpty)
                            Button("标记未读") { Task { await bulkRead(false) } }.disabled(chosen.isEmpty)
                            Button("下载未读章节") { Task { await bulkDownload() } }.disabled(chosen.isEmpty)
                            Button("从书架移除", role: .destructive) { removing = true }.disabled(chosen.isEmpty)
                        }
                    } else {
                        Button("筛选与显示", systemImage: "line.3.horizontal.decrease") { showingOptions = true }
                        Menu("书架操作", systemImage: "ellipsis") {
                            Button("选择漫画") { selecting = true }
                            Button("导入漫画") { importing = true }
                            NavigationLink("管理分类") { CategoryManagerView() }
                        }
                    }
                }
            }
            .overlay { if busy || library.importing { ProgressView("正在处理…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .task { options = .load(); rebuildMetrics() }
            .task(id: shelf.map(\.id)) { await library.refreshDownloadedChapters(bookIDs: Set(shelf.map(\.id))) }
            .onChange(of: library.changeCount) { _, _ in rebuildMetrics() }
            .onReceive(library.$downloadedChapters) { rebuildMetrics(downloaded: $0) }
            .onChange(of: options) { _, value in value.save() }
            .sheet(isPresented: $showingMore) { MoreView() }
            .sheet(isPresented: $showingOptions) { NavigationStack { LibraryDisplaySettingsView(options: $options) } }
            .sheet(isPresented: $categorySelection) { CategoryAssignmentView(bookIDs: chosen) }
            .navigationDestination(isPresented: Binding(get: { selectedBook != nil }, set: { if !$0 { selectedBook = nil } })) {
                if let book = selectedBook { BookDetailsView(book: book) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .zip, .image, UTType(filenameExtension: "cbz") ?? .data], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): Task { await library.importFiles(urls) }; case .failure(let error): library.errorMessage = error.localizedDescription }
            }
            .fileImporter(isPresented: $importingCover, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result, let book = coverBook { library.changeCover(book.id, input: url) }
                coverBook = nil
            }
            .alert("从书架移除？", isPresented: $removing) {
                Button("移除", role: .destructive) { for id in chosen { library.setFavorite(false, bookID: id) }; chosen = []; selecting = false }
                Button("取消", role: .cancel) {}
            } message: { Text("阅读历史和已下载的章节会保留。") }
            .alert("重命名", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("漫画名称", text: $title)
                Button("保存") { if let book = renaming { library.rename(book.id, title: title) }; renaming = nil }
                Button("取消", role: .cancel) { renaming = nil }
            }
            .alert("操作失败", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
                Button("好", role: .cancel) { library.errorMessage = nil }
            } message: { Text(library.errorMessage ?? "") }
        }
    }
    private func categoryButton(_ name: String, id: String) -> some View {
        Button { category = id } label: { Text(name).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6).background(category == id ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule()) }.buttonStyle(.plain)
    }
    private func select(_ book: ComicBook) {
        if selecting { if !chosen.insert(book.id).inserted { chosen.remove(book.id) } } else { selectedBook = book }
    }
    private func tile(_ book: ComicBook) -> some View {
        Button { select(book) } label: {
            VStack(alignment: .leading, spacing: 5) {
                cover(book).overlay(alignment: .topLeading) { badges(book) }
                if options.display != "cover" { Text(book.title).font(.caption.weight(.semibold)).lineLimit(2).foregroundStyle(.primary) }
                if options.showSource { Text(sourceName(book)).font(.caption2).lineLimit(1).foregroundStyle(.secondary) }
            }
        }.buttonStyle(.plain).contextMenu { context(book) }
        .onLongPressGesture { selecting = true; chosen.insert(book.id) }
    }
    private func row(_ book: ComicBook) -> some View {
        Button { select(book) } label: {
            HStack {
                cover(book).frame(width: 44, height: 66)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title).foregroundStyle(.primary)
                    if options.showSource { Text(sourceName(book)).font(.caption).foregroundStyle(.secondary) }
                    if options.showCount { Text("未读 \(metrics[book.id]?.unread ?? 0) · 共 \(metrics[book.id]?.chapters ?? 0) 章").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(); badges(book)
            }
        }.buttonStyle(.plain).contextMenu { context(book) }
    }
    @ViewBuilder private func badges(_ book: ComicBook) -> some View {
        HStack(spacing: 2) {
            if selecting { Image(systemName: chosen.contains(book.id) ? "checkmark.circle.fill" : "circle").padding(4).background(.regularMaterial, in: Circle()) }
            else if options.badges {
                if let m = metrics[book.id], m.unread > 0 { Text("\(m.unread)").padding(4).background(Color.accentColor).foregroundStyle(.white) }
                if let m = metrics[book.id], m.downloaded > 0 { Label("\(m.downloaded)", systemImage: "arrow.down").padding(4).background(.gray).foregroundStyle(.white) }
                if book.origin == nil { Text("本地").padding(4).background(.gray).foregroundStyle(.white) }
            }
        }.font(.caption2).clipShape(RoundedRectangle(cornerRadius: 4))
    }
    private func cover(_ book: ComicBook) -> some View {
        BookCover(book: book)
    }
    @ViewBuilder private func context(_ book: ComicBook) -> some View {
        Button("选择") { selecting = true; chosen.insert(book.id) }
        Button("分类") { chosen = [book.id]; categorySelection = true }
        Button("重命名") { title = book.title; renaming = book }
        Button("更换封面") { coverBook = book; importingCover = true }
        Button("刷新封面") { if let source = extensions.sources.first(where: { $0.id == book.origin?.sourceID }) { Task { await library.cacheSourceCover(book, source: source, refresh: true) } } }
        Button("从书架移除", role: .destructive) { chosen = [book.id]; removing = true }
    }
    private func sourceName(_ book: ComicBook) -> String { extensions.sources.first { $0.id == book.origin?.sourceID }?.name ?? "本地" }
    private func accepts(_ filter: String, _ value: Bool) -> Bool { filter == "all" || (filter == "yes" ? value : !value) }
    private func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending }
    private func rebuildMetrics(downloaded: [String: Set<String>]? = nil) {
        metrics = library.shelfMetrics(downloaded: downloaded)
    }
    private func getDetails(_ book: ComicBook) async throws -> (MangaSource, SourceDetails)? {
        guard let origin = book.origin, let source = extensions.sources.first(where: { $0.id == origin.sourceID }) else { return nil }
        if let details = library.cachedDetails(for: book) { return (source, details) }
        let manga = SourceManga(url: origin.mangaURL, title: book.title, thumbnail: origin.thumbnail, memo: origin.mangaMemo)
        let details = try await SourceEngine.call("details", ["source": source.id, "manga": SourceEngine.object(manga)], as: SourceDetails.self)
        library.saveDetails(details, source: source); return (source, details)
    }
    private func bulkRead(_ completed: Bool) async {
        busy = true; defer { busy = false }
        for book in shelf where chosen.contains(book.id) {
            do {
                if let (_, details) = try await getDetails(book) {
                    library.markChapters(details.chapters, bookID: book.id, completed: completed)
                    if completed && UserDefaults.standard.bool(forKey: "downloads.removeAfterMarked") {
                        for chapter in details.chapters { downloads.deleteIfAllowed(bookID: book.id, chapterURL: chapter.url) }
                    }
                }
                else if book.origin == nil { library.setPage(completed ? book.pageCount - 1 : 0, for: book.id) }
                else { throw SourceError.message("请安装此漫画的图源。") }
            } catch { library.errorMessage = book.title + "：" + error.localizedDescription }
        }
    }
    private func bulkDownload() async {
        busy = true; defer { busy = false }
        for book in shelf where chosen.contains(book.id) {
            do {
                if let (source, details) = try await getDetails(book) {
                    for chapter in details.chapters.reversed() where book.chapters?.first(where: { $0.url == chapter.url })?.completed != true {
                        downloads.enqueue(source: source, manga: details.manga, chapter: chapter)
                    }
                }
            } catch { library.errorMessage = book.title + "：" + error.localizedDescription }
        }
    }
}

func mangaStatus(_ status: Int?) -> String {
    switch status { case 1: "连载中"; case 2: "已完结"; case 3: "已授权"; case 4: "已出版"; case 5: "暂停"; case 6: "已取消"; default: "未知状态" }
}

struct LibraryDisplaySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var saved = LibraryDisplayOptions.load()
    var options: Binding<LibraryDisplayOptions>?
    private var value: Binding<LibraryDisplayOptions> { options ?? $saved }
    var body: some View {
        Form {
            Section("筛选") {
                filter("已下载", value.downloaded); filter("未读", value.unread); filter("已开始阅读", value.started)
                filter("已完结", value.completed); filter("有书签", value.bookmarked)
            }
            Section("排序") {
                Picker("排序方式", selection: value.sort) {
                    Text("漫画名称").tag("title"); Text("最近阅读").tag("recent"); Text("最新章节").tag("latest")
                    Text("未读章节数").tag("unread"); Text("总章节数").tag("chapters"); Text("加入日期").tag("added")
                    Text("检查更新日期").tag("fetched"); Text("手动排序").tag("manual"); Text("随机").tag("random")
                }
                Toggle("降序", isOn: value.descending)
            }
            Section("分组与显示") {
                Picker("分组", selection: value.grouping) { Text("分类").tag("category"); Text("图源").tag("source"); Text("状态").tag("status"); Text("作者").tag("author"); Text("不分组").tag("none") }
                Picker("显示模式", selection: value.display) { Text("封面与标题").tag("grid"); Text("仅封面").tag("cover"); Text("列表").tag("list") }
                Stepper("每行 \(value.wrappedValue.columns) 本", value: value.columns, in: 1...6)
                Toggle("显示未读与下载徽标", isOn: value.badges)
                Toggle("显示图源", isOn: value.showSource)
                Toggle("显示章节数", isOn: value.showCount)
            }
        }.navigationTitle("书架显示与筛选").navigationBarTitleDisplayMode(.inline)
        .onChange(of: saved) { _, v in v.save() }
        .toolbar { if options != nil { Button("完成") { dismiss() } } }
    }
    private func filter(_ name: String, _ binding: Binding<String>) -> some View { Picker(name, selection: binding) { Text("全部").tag("all"); Text("仅显示").tag("yes"); Text("排除").tag("no") } }
}

struct CategoryManagerView: View {
    @EnvironmentObject private var library: ComicLibrary
    @State private var name = ""
    @State private var old: String?
    @State private var editingName = false
    @State private var deleting: String?
    @AppStorage("library.defaultCategory") private var defaultCategory = ""
    var body: some View {
        List {
            Section {
                ForEach(library.categoryNames, id: \.self) { category in
                    Button(category) { old = category; name = category; editingName = true }
                        .swipeActions { Button("删除", role: .destructive) { deleting = category } }
                }.onMove { from, to in var names = library.categoryNames; names.move(fromOffsets: from, toOffset: to); library.reorderCategories(names) }
                Button("添加分类", systemImage: "plus") { old = nil; name = ""; editingName = true }
            }
            Section {
                Picker("默认分类", selection: $defaultCategory) {
                    Text("默认").tag(""); Text("每次询问").tag("ask")
                    ForEach(library.categoryNames, id: \.self) { Text($0).tag($0) }
                }
            }
        }.navigationTitle("分类").toolbar { EditButton() }
        .alert(old == nil ? "添加分类" : "重命名分类", isPresented: $editingName) {
            TextField("名称", text: $name)
            Button("保存") { if let old { library.renameCategory(old, to: name) } else { library.addCategory(name) } }
            Button("取消", role: .cancel) {}
        }
        .alert("删除分类？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let deleting { library.deleteCategory(deleting) }; deleting = nil }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("此分类中的漫画会保留在书架。") }
    }
}

struct CategoryAssignmentView: View {
    let bookIDs: Set<String>
    @EnvironmentObject private var library: ComicLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    var body: some View {
        NavigationStack {
            List {
                ForEach(library.categoryNames, id: \.self) { name in
                    Button { if !selected.insert(name).inserted { selected.remove(name) } } label: { HStack { Text(name); Spacer(); if selected.contains(name) { Image(systemName: "checkmark") } } }
                }
                NavigationLink("管理分类") { CategoryManagerView() }
                Text("可选择多个分类；不选择则放入默认分类。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("设置分类").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { library.setCategories(library.categoryNames.filter { selected.contains($0) }, bookIDs: bookIDs); dismiss() } }
            }
            .task { let books = library.books.filter { bookIDs.contains($0.id) }; selected = Set(books.first?.categories ?? []); for book in books.dropFirst() { selected.formIntersection(book.categories ?? []) } }
        }
    }
}
