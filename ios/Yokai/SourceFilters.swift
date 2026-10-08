import SwiftUI

struct SourceFilter: Codable, Identifiable {
    var id: Int { index }
    let index: Int
    let name: String
    let kind: String
    var value: AndroidPreferenceValue?
    var values: [String]?
    var children: [SourceFilter]?
    var selection: Int?
    var ascending: Bool?
}

struct SourceFilterForm: View {
    @Binding var filters: [SourceFilter]
    var body: some View {
        ForEach(filters.indices, id: \.self) { index in
            let item = filters[index]
            switch item.kind {
            case "group":
                DisclosureGroup(item.name) {
                    SourceFilterForm(filters: Binding(get: { filters[index].children ?? [] }, set: { filters[index].children = $0 }))
                }
            case "checkbox":
                Toggle(item.name, isOn: Binding(get: { if case .boolean(let v) = filters[index].value { return v }; return false }, set: { filters[index].value = .boolean($0) }))
            case "triState":
                Picker(item.name, selection: integer(index)) { Text("不限").tag(0); Text("包含").tag(1); Text("排除").tag(2) }
            case "select":
                Picker(item.name, selection: integer(index)) { ForEach(Array((item.values ?? []).enumerated()), id: \.offset) { Text($0.element).tag($0.offset) } }
            case "sort":
                Picker(item.name, selection: Binding(get: { filters[index].selection ?? -1 }, set: { filters[index].selection = $0 })) {
                    Text("默认").tag(-1)
                    ForEach(Array((item.values ?? []).enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                }
                Toggle("升序", isOn: Binding(get: { filters[index].ascending ?? false }, set: { filters[index].ascending = $0 }))
            case "text":
                TextField(item.name, text: Binding(get: { if case .string(let v) = filters[index].value { return v }; return "" }, set: { filters[index].value = .string($0) }))
            case "separator": Divider()
            default: Text(item.name).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func integer(_ index: Int) -> Binding<Int> {
        Binding(get: { if case .integer(let v) = filters[index].value { return Int(v) }; return 0 }, set: { filters[index].value = .integer(Int64($0)) })
    }
}

struct SavedSourceSearch: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var query: String
    var filters: [SourceFilter]
    static func read(_ source: String) -> [Self] {
        YokaiStorage.defaults.data(forKey: "source.savedSearches." + source).flatMap { try? JSONDecoder().decode([Self].self, from: $0) } ?? []
    }
    static func save(_ searches: [Self], source: String) {
        if let data = try? JSONEncoder().encode(searches) { YokaiStorage.defaults.set(data, forKey: "source.savedSearches." + source) }
    }
}

struct GlobalSearchView: View {
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var query = ""
    @State private var results: [String: [SourceManga]] = [:]
    @State private var errors: [String: String] = [:]
    @State private var searching: Task<Void, Never>?
    @State private var busy = false
    @AppStorage("sources.searchPinnedOnly", store: YokaiStorage.defaults) private var pinnedOnly = false
    private var sources: [MangaSource] {
        let pinned = YokaiStorage.defaults.stringArray(forKey: "sources.pinned") ?? []
        let hidden = YokaiStorage.defaults.stringArray(forKey: "sources.hidden") ?? []
        return extensions.sources.filter { $0.error == nil && !hidden.contains($0.id) && (!pinnedOnly || pinned.contains($0.id)) }
    }
    var body: some View {
        List {
            Toggle("仅搜索置顶图源", isOn: $pinnedOnly)
            if busy { ProgressView("正在搜索…") }
            ForEach(sources) { source in
                if results[source.id] != nil || errors[source.id] != nil {
                    Section(source.name ?? source.package) {
                        ForEach(results[source.id] ?? []) { manga in
                            NavigationLink { SourceDetailsView(source: source, manga: manga) } label: {
                                HStack { MangaCover(source: source, url: manga.thumbnail).frame(width: 44, height: 66); Text(manga.title) }
                            }
                        }
                        if let error = errors[source.id] { Text(error).font(.caption).foregroundStyle(.red) }
                        else if results[source.id]?.isEmpty == true { Text("没有找到结果").foregroundStyle(.secondary) }
                        NavigationLink("在此图源继续搜索") { SourceBrowseView(source: source, initialQuery: query) }
                    }
                }
            }
        }.navigationTitle("全局搜索").searchable(text: $query, prompt: "搜索所有启用的图源")
        .onSubmit(of: .search) { search() }
        .toolbar { if busy { Button("取消") { searching?.cancel(); busy = false } } }
        .onDisappear { searching?.cancel() }
    }
    private func search() {
        searching?.cancel(); results = [:]; errors = [:]
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }; busy = true
        searching = Task {
            for source in sources {
                guard !Task.isCancelled else { return }
                do {
                    let result = try await SourceEngine.call("search", ["source": source.id, "query": text, "page": 1], as: SourceResults.self)
                    guard !Task.isCancelled else { return }; results[source.id] = result.manga
                } catch { if !Task.isCancelled { errors[source.id] = error.localizedDescription } }
            }
            busy = false
        }
    }
}
