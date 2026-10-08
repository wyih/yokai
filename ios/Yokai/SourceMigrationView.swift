import SwiftUI

struct SourceMigrationView: View {
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var selected: ComicBook?
    var body: some View {
        List(library.books.filter { $0.inLibrary != false && $0.origin != nil }) { book in
            NavigationLink(book.title) { MigrationSearchView(original: book) }
        }.navigationTitle("迁移图源")
    }
}

private struct MigrationSearchView: View {
    let original: ComicBook
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var sourceID = ""
    @State private var query = ""
    @State private var results: [SourceManga] = []
    @State private var busy = false
    @State private var error: String?
    @State private var destination: SourceDetails?
    @State private var confirmed = false
    @State private var removeOriginal = true
    @State private var result: ComicBook?
    private var source: MangaSource? { extensions.sources.first { $0.id == sourceID } }
    var body: some View {
        List {
            Section {
                Picker("新图源", selection: $sourceID) {
                    Text("选择图源").tag("")
                    ForEach(extensions.sources.filter { $0.error == nil && $0.id != original.origin?.sourceID }) { Text($0.name ?? $0.package).tag($0.id) }
                }
                TextField("搜索漫画", text: $query).onSubmit { Task { await search() } }
                Button("搜索") { Task { await search() } }.disabled(source == nil || busy)
            }
            if busy { ProgressView("正在加载…") }
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(results) { manga in
                Button(manga.title) { Task { await preview(manga) } }
            }
        }.navigationTitle("迁移 · \(original.title)")
        .task { query = original.title }
        .sheet(isPresented: $confirmed) {
            NavigationStack {
                Form {
                    if let destination {
                        LabeledContent("原漫画", value: original.title)
                        LabeledContent("新漫画", value: destination.manga.title)
                        LabeledContent("新图源", value: source?.name ?? "")
                        LabeledContent("可匹配的章节记录", value: "\(matches(destination).count) / \((original.chapters ?? []).count)")
                        Toggle("迁移后从书架移除原漫画", isOn: $removeOriginal)
                        Text("按章节编号或名称匹配阅读进度、章节书签和历史。原图源的下载文件保留。").font(.footnote).foregroundStyle(.secondary)
                        Button("确认迁移") { migrate(destination) }.buttonStyle(.borderedProminent)
                    }
                }.navigationTitle("确认迁移").toolbar { Button("取消") { confirmed = false } }
            }
        }
        .navigationDestination(isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) { if let result { BookDetailsView(book: result) } }
    }
    private func search() async {
        guard let source else { return }; busy = true; error = nil; defer { busy = false }
        do { results = try await SourceEngine.call("search", ["source": source.id, "query": query, "page": 1], as: SourceResults.self).manga }
        catch { self.error = error.localizedDescription }
    }
    private func preview(_ manga: SourceManga) async {
        guard let source else { return }; busy = true; error = nil; defer { busy = false }
        do { destination = try await SourceEngine.call("details", ["source": source.id, "manga": SourceEngine.object(manga)], as: SourceDetails.self); confirmed = true }
        catch { self.error = error.localizedDescription }
    }
    private func matches(_ details: SourceDetails) -> [String: String] {
        let previous = library.cachedDetails(for: original)?.chapters ?? []
        var matches: [String: String] = [:]
        for state in original.chapters ?? [] {
            let old = previous.first { $0.url == state.url }
            let match = details.chapters.first { chapter in
                if let old, old.number >= 0, chapter.number >= 0 { return abs(old.number - chapter.number) < 0.00001 }
                return chapter.name.trimmingCharacters(in: .whitespacesAndNewlines) == state.title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let match { matches[state.url] = match.url }
        }
        return matches
    }
    private func migrate(_ details: SourceDetails) {
        guard let source else { return }
        let book = library.addOnline(details.manga, source: source)
        library.saveDetails(details, source: source)
        library.applyMigration(from: original, to: book.id, matches: matches(details), chapters: details.chapters, removeOriginal: removeOriginal)
        confirmed = false; result = library.books.first { $0.id == book.id }
    }
}
