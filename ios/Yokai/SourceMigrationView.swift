import SwiftUI

struct SourceMigrationView: View {
    @EnvironmentObject private var library: ComicLibrary
    var body: some View {
        List(library.books.filter { $0.inLibrary != false && $0.origin != nil }) { book in
            NavigationLink(book.title) { MigrationSearchView(original: book) }
        }.navigationTitle("迁移图源")
    }
}

enum MigrationSearchUpdate {
    case searching, matches(Int), failed(String), migrated(ComicBook), skipped
}

struct MigrationSearchView: View {
    let original: ComicBook
    var targetSourceID: String?
    var unavailableDestinationIDs: Set<String> = []
    var onUpdate: ((MigrationSearchUpdate) -> Void)?
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var sourceID = ""
    @State private var query = ""
    @State private var results: [SourceManga] = []
    @State private var page = 0
    @State private var hasNext = false
    @State private var initialized = false
    @State private var busy = false
    @State private var saving = false
    @State private var error: String?
    @State private var destination: SourceDetails?
    @State private var confirmed = false
    @State private var removeOriginal = true
    @State private var result: ComicBook?
    init(original: ComicBook, targetSourceID: String? = nil, unavailableDestinationIDs: Set<String> = [], onUpdate: ((MigrationSearchUpdate) -> Void)? = nil) {
        self.original = original; self.targetSourceID = targetSourceID
        self.unavailableDestinationIDs = unavailableDestinationIDs; self.onUpdate = onUpdate
        _sourceID = State(initialValue: targetSourceID ?? "")
        _query = State(initialValue: original.title)
    }
    private var source: MangaSource? { extensions.sources.first { $0.id == sourceID && $0.error == nil } }
    private var currentOriginal: ComicBook { library.books.first { $0.id == original.id } ?? original }
    var body: some View {
        List {
            Section {
                if targetSourceID != nil {
                    LabeledContent("新图源", value: source?.name ?? sourceID)
                } else {
                    Picker("新图源", selection: $sourceID) {
                        Text("选择图源").tag("")
                        ForEach(extensions.sources.filter { $0.error == nil && $0.id != original.origin?.sourceID }) { Text($0.name ?? $0.package).tag($0.id) }
                    }
                }
                TextField("搜索漫画", text: $query).onSubmit { Task { await search() } }
                    .accessibilityIdentifier("migrationQuery")
                Button("搜索") { Task { await search() } }.disabled(source == nil || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(busy)
            if busy { ProgressView("正在加载…") }
            if let error { Text(error).foregroundStyle(.red) }
            if page > 0 && results.isEmpty && !busy {
                Text("没有找到匹配漫画，可以修改名称重新搜索。")
            }
            ForEach(results) { manga in
                Button { Task { await preview(manga) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manga.title)
                        if let author = manga.author, !author.isEmpty { Text(author).font(.caption).foregroundStyle(.secondary) }
                    }
                }.disabled(busy).accessibilityIdentifier("migrationMatch." + manga.id)
            }
            if hasNext { Button("加载更多结果") { Task { await search(nextPage: true) } }.disabled(busy) }
        }.navigationTitle("迁移 · \(original.title)")
        .navigationBarBackButtonHidden(saving)
        .onChange(of: sourceID) { _, _ in results = []; page = 0; hasNext = false; destination = nil; error = nil }
        .onChange(of: query) { _, _ in results = []; page = 0; hasNext = false }
        .task {
            guard !initialized else { return }; initialized = true
            if targetSourceID != nil { await search() }
        }
        .toolbar {
            if onUpdate != nil { Button("跳过这本") { onUpdate?(.skipped) }.disabled(busy) }
        }
        .sheet(isPresented: $confirmed) {
            NavigationStack {
                Form {
                    if let destination {
                        let matches = chapterMatches(destination)
                        let canRemove = SourceMigration.canRemoveOriginal(currentOriginal, matches: matches)
                        LabeledContent("原漫画", value: currentOriginal.title)
                        LabeledContent("新漫画", value: destination.manga.title)
                        LabeledContent("新图源", value: source?.name ?? sourceID)
                        if let author = destination.manga.author { LabeledContent("作者", value: author) }
                        LabeledContent("可匹配的章节记录", value: "\(matches.count) / \(SourceMigration.recordedChapterURLs(currentOriginal).count)")
                        if canRemove { Toggle("迁移后从书架移除原漫画", isOn: $removeOriginal) }
                        else { Text("部分记录没有唯一匹配，原漫画会继续保留在书架，方便核对进度、书签和历史。") }
                        if let source, library.books.contains(where: { $0.id == ComicLibrary.hash(source.id + "\n" + destination.manga.url) }) {
                            Text("目标漫画已有本地记录，确认后将合并章节记录、书签和分类。")
                        }
                        Text("按章节编号或名称匹配阅读进度、章节书签和历史。原图源的下载文件保留。").font(.footnote).foregroundStyle(.secondary)
                        if let error { Text(error).foregroundStyle(.red) }
                        Button(busy ? "正在保存…" : "确认迁移") { Task { await migrate(destination) } }
                            .buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("confirmMigration")
                    }
                }.navigationTitle("确认迁移").toolbar { Button("取消") { confirmed = false }.disabled(busy) }
            }.interactiveDismissDisabled(busy)
        }
        .navigationDestination(isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) { if let result { BookDetailsView(book: result) } }
    }
    private func search(nextPage: Bool = false) async {
        guard !busy else { return }
        guard let source else { fail("目标图源不可用，请重新选择图源。"); return }
        let requestedPage = nextPage ? page + 1 : 1
        busy = true; error = nil; onUpdate?(.searching); defer { busy = false }
        do {
            let response = try await SourceEngine.call("search", ["source": source.id, "query": query, "page": requestedPage], as: SourceResults.self)
            try Task.checkCancellation()
            var seen = Set<String>()
            results = ((nextPage ? results : []) + response.manga).filter { seen.insert($0.id).inserted }
            page = requestedPage; hasNext = response.hasNext; onUpdate?(.matches(results.count))
        } catch is CancellationError {} catch { fail(error.localizedDescription) }
    }
    private func preview(_ manga: SourceManga) async {
        guard let source, !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            let details = try await SourceEngine.call("details", ["source": source.id, "manga": SourceEngine.object(manga)], as: SourceDetails.self)
            try Task.checkCancellation()
            let id = ComicLibrary.hash(source.id + "\n" + details.manga.url)
            guard id != original.id, !unavailableDestinationIDs.contains(id) else {
                throw SourceError.message("这本漫画已在本批次中使用，请选择另一个匹配或跳过。")
            }
            destination = details; confirmed = true
        } catch is CancellationError {} catch { fail(error.localizedDescription) }
    }
    private func chapterMatches(_ details: SourceDetails) -> [String: String] {
        SourceMigration.matches(original: currentOriginal, previous: library.cachedDetails(for: currentOriginal)?.chapters ?? [], destination: details.chapters)
    }
    private func migrate(_ details: SourceDetails) async {
        guard let source, !busy else { return }; busy = true; saving = true; error = nil
        defer { busy = false; saving = false }
        do {
            let book = try await SourceMigration.apply(original: currentOriginal, source: source, details: details, library: library, removeOriginal: removeOriginal)
            confirmed = false
            if let onUpdate { onUpdate(.migrated(book)) } else { result = book }
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) { error = message; onUpdate?(.failed(message)) }
}

// Single and batch migration share matching, preservation and durable saving.
enum SourceMigration {
    static func recordedChapterURLs(_ original: ComicBook) -> Set<String> {
        var urls = Set((original.chapters ?? []).map(\.url))
        urls.formUnion(original.bookmarks.filter { !$0.deleted }.compactMap(\.chapterURL))
        if let current = original.origin?.chapterURL { urls.insert(current) }
        return urls
    }
    static func canRemoveOriginal(_ original: ComicBook, matches: [String: String]) -> Bool {
        recordedChapterURLs(original).isSubset(of: Set(matches.keys))
            && !original.bookmarks.contains { !$0.deleted && $0.chapterURL == nil }
            && (original.lastRead == nil || original.origin?.chapterURL != nil)
    }
    static func matches(original: ComicBook, previous: [SourceChapter], destination: [SourceChapter]) -> [String: String] {
        var matches: [String: String] = [:]
        for url in recordedChapterURLs(original) {
            let old = previous.first { $0.url == url }
            let title = (old?.name ?? original.chapters?.first { $0.url == url }?.title
                ?? (original.origin?.chapterURL == url ? original.origin?.chapterTitle : nil))?.trimmingCharacters(in: .whitespacesAndNewlines)
            let numbered = old.flatMap { old in old.number >= 0 ? destination.filter { $0.number >= 0 && abs(old.number - $0.number) < 0.00001 } : nil } ?? []
            let named = (numbered.isEmpty ? destination : numbered).filter {
                guard let title, !title.isEmpty else { return false }
                return $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == title
            }
            if numbered.count == 1 { matches[url] = numbered[0].url }
            else if named.count == 1 { matches[url] = named[0].url }
        }
        // Ambiguous many-to-one mappings must not overwrite another chapter's progress.
        let counts = Dictionary(grouping: matches.values, by: { $0 }).mapValues(\.count)
        return matches.filter { counts[$0.value] == 1 }
    }
    @MainActor static func apply(original: ComicBook, source: MangaSource, details: SourceDetails, library: ComicLibrary, removeOriginal: Bool) async throws -> ComicBook {
        guard source.id != original.origin?.sourceID else { throw SourceError.message("请选择不同的目标图源。") }
        guard library.books.contains(where: { $0.id == original.id }) else { throw SourceError.message("原漫画已移除，请重新选择。") }
        let id = ComicLibrary.hash(source.id + "\n" + details.manga.url)
        try library.cacheImportedDetails(details, bookID: id)
        _ = library.addOnline(details.manga, source: source, favorite: original.inLibrary != false)
        library.errorMessage = nil
        library.saveDetails(details, source: source)
        if let error = library.errorMessage { throw SourceError.message(error) }
        try await library.flushPendingSaves()
        guard let current = library.books.first(where: { $0.id == original.id }) else { throw SourceError.message("原漫画已移除，请重新选择。") }
        let matches = matches(original: current, previous: library.cachedDetails(for: current)?.chapters ?? [], destination: details.chapters)
        library.applyMigration(from: current, to: id, matches: matches, chapters: details.chapters, removeOriginal: false)
        try await library.flushPendingSaves()
        guard let migrated = library.books.first(where: { $0.id == id }) else { throw SourceError.message("迁移结果无法读取，请重试。") }
        for old in current.chapters ?? [] {
            guard let url = matches[old.url] else { continue }
            let copied = migrated.chapters?.first { $0.url == url }
            if (old.bookmarked == true && copied?.bookmarked != true)
                || (copied?.lastRead ?? .distantPast) < (old.lastRead ?? .distantPast) {
                throw SourceError.message("目标章节已有记录，部分书签或历史未能合并。原漫画仍保留在书架，请稍后重试。")
            }
        }
        if removeOriginal && canRemoveOriginal(current, matches: matches) {
            library.setFavorite(false, bookID: original.id)
            do { try await library.flushPendingSaves() }
            catch { library.setFavorite(current.inLibrary != false, bookID: original.id); throw error }
        }
        guard let result = library.books.first(where: { $0.id == id }) else { throw SourceError.message("迁移结果无法读取，请重试。") }
        return result
    }
}
