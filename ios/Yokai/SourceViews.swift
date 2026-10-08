import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SourcesView: View {
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var importing = false
    @State private var section = "sources"
    @State private var showingMore = false
    @State private var configuringSource: MangaSource?
    @State private var query = ""
    @State private var pinned = UserDefaults.standard.stringArray(forKey: "sources.pinned") ?? []
    @State private var hidden = UserDefaults.standard.stringArray(forKey: "sources.hidden") ?? []
    @State private var language = "all"
    @State private var showHidden = false
    @State private var addingRepository = false
    @State private var repositoryName = ""
    @State private var repositoryURL = ""
    @State private var uninstalling: InstalledExtension?
    @AppStorage("extensions.autoCheck") private var autoCheck = false
    @AppStorage("extensions.autoInstall") private var autoInstall = false
    private var sources: [MangaSource] {
        extensions.sources.filter {
            (showHidden || !hidden.contains($0.id)) && (language == "all" || $0.lang == language)
                && (query.isEmpty || ($0.name ?? $0.package).localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            if pinned.contains(a.id) != pinned.contains(b.id) { return pinned.contains(a.id) }
            return (a.name ?? a.package).localizedStandardCompare(b.name ?? b.package) == .orderedAscending
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Picker("浏览", selection: $section) { Text("图源").tag("sources"); Text("插件").tag("extensions"); Text("迁移").tag("migration") }.pickerStyle(.segmented)
                if section == "sources" {
                    Picker("语言", selection: $language) {
                        Text("全部").tag("all")
                        ForEach(Array(Set(extensions.sources.compactMap(\.lang))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("显示已隐藏的图源", isOn: $showHidden)
                    Section("图源") {
                        ForEach(sources) { source in
                            if let error = source.error { VStack(alignment: .leading) { Text(source.package); Text(error).font(.caption).foregroundStyle(.red) } }
                            else {
                                HStack {
                                    NavigationLink { SourceBrowseView(source: source) } label: {
                                        HStack { Image(systemName: "books.vertical"); VStack(alignment: .leading) { Text(source.name ?? source.package); Text(source.lang ?? "").font(.caption).foregroundStyle(.secondary) }; if pinned.contains(source.id) { Image(systemName: "pin.fill").font(.caption) } }
                                    }
                                    Button("图源设置", systemImage: "gearshape") { configuringSource = source }.labelStyle(.iconOnly).buttonStyle(.borderless)
                                }.contextMenu {
                                    Button(pinned.contains(source.id) ? "取消置顶" : "置顶") { toggle(source.id, in: &pinned); UserDefaults.standard.set(pinned, forKey: "sources.pinned") }
                                    Button(hidden.contains(source.id) ? "显示" : "隐藏") { toggle(source.id, in: &hidden); UserDefaults.standard.set(hidden, forKey: "sources.hidden") }
                                }
                            }
                        }
                        if extensions.busy { ProgressView("正在准备插件…") }
                    }
                }
                if section == "migration" { NavigationLink("从书架选择漫画迁移") { SourceMigrationView() } }
                if section == "extensions" {
                    Section("插件") {
                        ForEach(extensions.installed) { item in
                            HStack { Text(item.package.components(separatedBy: ".").last ?? item.package); Spacer(); Text(item.version).foregroundStyle(.secondary) }
                                .swipeActions { Button("卸载", role: .destructive) { uninstalling = item } }
                        }
                        Button("导入 APK / JAR 插件", systemImage: "plus") { importing = true }.disabled(extensions.busy)
                        Button("检查插件更新", systemImage: "arrow.triangle.2.circlepath") { Task { await extensions.checkUpdates() } }.disabled(extensions.busy)
                        NavigationLink("从仓库安装插件") { ExtensionCatalogView() }
                        ForEach(extensions.updates) { item in Button("更新 \(item.name) 至 \(item.version)") { Task { await extensions.update(item) } }.disabled(extensions.busy) }
                        if let message = extensions.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section("扩展仓库") {
                        ForEach(extensions.repositories) { repository in VStack(alignment: .leading, spacing: 6) { Text(repository.name); Text(repository.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }.swipeActions { Button("移除", role: .destructive) { extensions.removeRepository(repository.id) } } }
                        Button("添加仓库") { repositoryName = ""; repositoryURL = ""; addingRepository = true }
                    }
                    Section("插件更新") {
                        Toggle("每天自动检查更新", isOn: $autoCheck)
                        if autoCheck { Toggle("自动安装插件更新", isOn: $autoInstall) }
                    }
                }
            }.navigationTitle("浏览").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索图源")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("更多", systemImage: "line.3.horizontal") { showingMore = true } }
                ToolbarItem(placement: .topBarTrailing) { NavigationLink { GlobalSearchView() } label: { Image(systemName: "globe.desk") }.accessibilityLabel("全局搜索") }
            }
            .sheet(isPresented: $showingMore) { MoreView() }
            .sheet(item: $configuringSource) { SourcePreferencesView(source: $0) }
            .task { await extensions.start() }
            .alert("添加扩展仓库", isPresented: $addingRepository) {
                TextField("名称", text: $repositoryName); TextField("HTTPS 索引地址", text: $repositoryURL).textInputAutocapitalization(.never)
                Button("添加") { extensions.addRepository(name: repositoryName, address: repositoryURL) }
                Button("取消", role: .cancel) {}
            }
            .alert("卸载插件？", isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } })) {
                Button("卸载", role: .destructive) { if let item = uninstalling { Task { await extensions.uninstall(item.package) } }; uninstalling = nil }
                Button("取消", role: .cancel) { uninstalling = nil }
            } message: { Text("书架和已下载章节会保留，在线访问需要重新安装插件。") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data, UTType(filenameExtension: "jar") ?? .data]) { result in
                if case .success(let url) = result { Task { await extensions.importExtension(url) } }
            }
        }
    }
    private func toggle(_ id: String, in items: inout [String]) { if items.contains(id) { items.removeAll { $0 == id } } else { items.append(id) } }
}

struct SourceBrowseView: View {
    let source: MangaSource
    var initialQuery = ""
    @State private var query = ""
    @State private var manga: [SourceManga] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var busy = false
    @State private var error: String?
    @State private var latest = false
    @State private var settings = false
    @State private var webView = false
    @State private var filters: [SourceFilter] = []
    @State private var filtering = false
    @State private var editingFilters = false
    @State private var saved: [SavedSourceSearch] = []
    @State private var savingSearch = false
    @State private var searchName = ""
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 22) {
                ForEach(manga) { item in
                    NavigationLink { SourceDetailsView(source: source, manga: item) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            MangaCover(source: source, url: item.thumbnail)
                            Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding()
            if busy { ProgressView("正在加载…").padding() }
            if let error {
                Text(error).foregroundStyle(.red).padding()
                HStack {
                    Button("重试") { Task { await load(reset: true) } }
                    Button("打开 WebView", systemImage: "globe") { webView = true }
                    Button("图源设置") { settings = true }
                }.padding(.bottom)
            }
            if hasNext && !busy { Button("加载下一页") { Task { await load(reset: false) } }.padding() }
        }
        .navigationTitle(source.name ?? "漫画源")
        .searchable(text: $query, prompt: "搜索此漫画源")
        .onSubmit(of: .search) { Task { await load(reset: true) } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if source.latest == true { Button(latest ? "热门" : "最新") { latest.toggle(); filtering = false; Task { await load(reset: true) } } }
                Menu("搜索与筛选", systemImage: "line.3.horizontal.decrease") {
                    Button("筛选") { editingFilters = true }
                    Button("保存当前搜索") { searchName = query.isEmpty ? "已保存的筛选" : query; savingSearch = true }
                    ForEach(saved) { search in
                        Menu(search.name) {
                            Button("使用") { query = search.query; filters = search.filters; filtering = true; Task { await load(reset: true) } }
                            Button("删除", role: .destructive) { saved.removeAll { $0.id == search.id }; SavedSourceSearch.save(saved, source: source.id) }
                        }
                    }
                }
                Button("图源设置", systemImage: "gearshape") { settings = true }
                Button("打开 WebView", systemImage: "globe") { webView = true }
            }
        }
        .sheet(isPresented: $settings, onDismiss: { Task { await load(reset: true) } }) { SourcePreferencesView(source: source) }
        .sheet(isPresented: $webView, onDismiss: { Task { await load(reset: true) } }) { SourceLoginView(source: source) }
        .task {
            query = initialQuery; saved = SavedSourceSearch.read(source.id)
            do { filters = try await SourceEngine.call("filters", ["source": source.id], as: [SourceFilter].self) } catch { self.error = error.localizedDescription }
            await load(reset: true)
        }
        .sheet(isPresented: $editingFilters) {
            NavigationStack {
                Form {
                    SourceFilterForm(filters: $filters)
                    if filters.isEmpty { Text("此图源没有提供筛选项。") }
                    Button("重置筛选") { Task { do { filters = try await SourceEngine.call("filters", ["source": source.id], as: [SourceFilter].self) } catch { self.error = error.localizedDescription }; filtering = false } }
                }.navigationTitle("筛选").toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editingFilters = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("搜索") { filtering = true; editingFilters = false; Task { await load(reset: true) } } }
                }
            }
        }
        .alert("保存搜索", isPresented: $savingSearch) {
            TextField("名称", text: $searchName)
            Button("保存") { let name = searchName.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty { saved.append(SavedSourceSearch(name: name, query: query, filters: filters)); SavedSourceSearch.save(saved, source: source.id) } }
            Button("取消", role: .cancel) {}
        }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let next = reset ? 1 : page + 1
            var arguments: [String: Any] = ["source": source.id, "page": next, "query": query]
            if filtering { arguments["filters"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(filters)) }
            let result = try await SourceEngine.call(query.isEmpty && !filtering ? (latest ? "latest" : "popular") : "search", arguments, as: SourceResults.self)
            let existing = reset ? [] : manga
            var seen = Set(existing.map(\.id))
            manga = existing + result.manga.filter { seen.insert($0.id).inserted }
            page = next; hasNext = result.hasNext
        } catch { self.error = error.localizedDescription }
    }
}

struct MangaCover: View {
    let source: MangaSource
    let url: String?
    @State private var image: UIImage?
    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: source.id + "\n" + (url ?? "")) {
                image = nil
                guard let url, !url.isEmpty else { return }
                image = try? await SourceCoverCache.load(source: source, url: url)
            }
    }
}

@MainActor enum SourceCoverCache {
    private static let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 32 * 1024 * 1024; return cache
    }()
    static func load(source: MangaSource, url: String, refresh: Bool = false) async throws -> UIImage {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SourceCovers")
        let key = ComicLibrary.hash(source.id + "\n" + url)
        let file = root.appendingPathComponent(key)
        if !refresh, let cached = memory.object(forKey: key as NSString) { return cached }
        if !refresh, let cached = await Task.detached(priority: .utility, operation: {
            UIImage(contentsOfFile: file.path)?.preparingThumbnail(of: CGSize(width: 360, height: 540))
        }).value { remember(cached, key: key); return cached }
        let headers = try await SourceEngine.call("imageRequest", ["source": source.id, "url": url], as: [String: String].self)
        guard let address = URL(string: url), ["https", "http"].contains(address.scheme?.lowercased() ?? "") else {
            throw SourceError.message("图源没有提供有效的封面地址。")
        }
        var request = URLRequest(url: address)
        if refresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        for (key, value) in headers where key.lowercased() != "accept-encoding" { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SourceError.message("图源返回了封面请求错误（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        let image = try await Task.detached(priority: .utility) {
            guard let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 360, height: 540)) else { throw SourceError.message("图源返回的封面无法读取。") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return image
        }.value
        remember(image, key: key)
        return image
    }
    private static func remember(_ image: UIImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
    }
}

struct SourcePreferencesView: View {
    let source: MangaSource
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [[String: Any]] = []
    @State private var error: String?
    @State private var values: [String: String] = [:]
    @State private var selectedValues: [String: [String]] = [:]
    @State private var login = false
    @State private var loginURL: URL?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("打开 WebView", systemImage: "globe") { loginURL = nil; login = true }
                    ForEach(entries.indices, id: \.self) { index in
                        let item = entries[index], key = item["key"] as? String ?? ""
                        let title = item["title"] as? String ?? key
                        Group {
                        if item["category"] as? Bool == true { Text(title).font(.headline) }
                        else if key.isEmpty || (item["clickable"] as? Bool == true && item["value"] == nil) {
                            Button(title) { Task { await click(item["index"] as? Int ?? index) } }
                        } else if item["valueType"] as? String == "set", let choices = item["entries"] as? [String], let codes = item["values"] as? [String] {
                            DisclosureGroup(title) {
                                ForEach(Array(zip(choices, codes)), id: \.1) { choice, code in
                                    Toggle(choice, isOn: Binding(get: { selectedValues[key, default: []].contains(code) }, set: { enabled in
                                        var selected = selectedValues[key, default: []]
                                        if enabled { selected.append(code) } else { selected.removeAll { $0 == code } }
                                        selectedValues[key] = selected
                                        Task { await save(key, value: selected) }
                                    }))
                                }
                            }
                        } else if let choices = item["entries"] as? [String], let codes = item["values"] as? [String] {
                            Picker(title, selection: Binding(get: { values[key] ?? "" }, set: { value in values[key] = value; Task { await save(key, value: value) } })) {
                                ForEach(Array(zip(choices, codes)), id: \.1) { Text($0.0).tag($0.1) }
                            }
                        } else if item["valueType"] as? String == "boolean" {
                            Toggle(title, isOn: Binding(get: { values[key] == "true" }, set: { values[key] = $0 ? "true" : "false"; let value = $0; Task { await save(key, value: value) } }))
                        } else {
                            SourcePreferenceTextInput(title: title, initial: values[key] ?? "",
                                secure: ["password", "token", "secret", "密码", "令牌"].contains(where: { (key + title).localizedCaseInsensitiveContains($0) })) { value in
                                values[key] = value
                                Task { await saveText(key, value: value, item: item) }
                            }
                        }
                        }.disabled(item["enabled"] as? Bool == false)
                        if let summary = item["summary"] as? String, !summary.isEmpty { Text(summary).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            .navigationTitle("图源设置")
            .toolbar { Button("完成") { dismiss() } }
            .task { await load() }
            .sheet(isPresented: $login, onDismiss: { Task { await load() } }) { SourceLoginView(source: source, address: loginURL) }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("YokaiSourceWebView"))) { notification in
                guard let info = notification.object as? [String: String], info["source"] == source.id,
                      let raw = info["url"], let url = URL(string: raw) else { return }
                loginURL = url; login = true
            }
        }
    }
    private func load() async {
        do {
            let result: String = try await rawPreferences()
            entries = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]] ?? []
            for item in entries {
                if let key = item["key"] as? String {
                    if item["valueType"] as? String == "set" { selectedValues[key] = item["value"] as? [String] ?? [] }
                    else if item["valueType"] as? String == "boolean", let flag = item["value"] as? Bool { values[key] = flag ? "true" : "false" }
                    else if let number = item["value"] as? NSNumber { values[key] = number.stringValue }
                    else { values[key] = item["value"] as? String ?? "" }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func rawPreferences() async throws -> String {
        let entries = try await SourceEngine.call("preferences", ["source": source.id], as: [SourcePreferenceRecord].self)
        return String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
    }
    private func save(_ key: String, value: Any) async {
        do { let _: Bool = try await SourceEngine.call("setPreference", ["source": source.id, "key": key, "value": value], as: Bool.self); error = nil }
        catch { self.error = error.localizedDescription; await load() }
    }
    private func saveText(_ key: String, value: String, item: [String: Any]) async {
        if item["valueType"] as? String == "number" {
            if let integer = Int64(value) { await save(key, value: integer) }
            else if let decimal = Double(value), decimal.isFinite { await save(key, value: decimal) }
            else { error = "请输入有效数字。" }
        } else { await save(key, value: value) }
    }
    private func click(_ index: Int) async {
        do { let _: Bool = try await SourceEngine.call("clickPreference", ["source": source.id, "index": index], as: Bool.self) }
        catch { self.error = error.localizedDescription }
    }
}

// Keep each draft local so typing does not rebuild the entire plugin form.
private struct SourcePreferenceTextInput: View {
    let title: String
    let initial: String
    let secure: Bool
    let save: (String) -> Void
    @State private var draft: String

    init(title: String, initial: String, secure: Bool, save: @escaping (String) -> Void) {
        self.title = title; self.initial = initial; self.secure = secure; self.save = save
        _draft = State(initialValue: initial)
    }
    var body: some View {
        Group {
            Group {
                if secure { SecureField(title, text: $draft) }
                else { TextField(title, text: $draft) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { save(draft) }
            Button("保存\(title)") { save(draft) }
        }.onChange(of: initial) { _, value in draft = value }
    }
}

private struct SourcePreferenceRecord: Codable {
    var index: Int
    var key: String?
    var title: String?
    var summary: String?
    var enabled: Bool?
    var kind: String?
    var clickable: Bool?
    var category: Bool?
    var value: AndroidPreferenceValue?
    var valueType: String?
    var entries: [String]?
    var values: [String]?
}

struct SourceLoginView: View {
    let source: MangaSource
    var address: URL? = nil
    var manga: SourceManga? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = SourceWebSession()
    @State private var editingAddress = false
    @State private var addressText = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = session.error {
                    Text(error).font(.footnote).foregroundStyle(.red).padding()
                }
                SourceWebView(session: session)
                HStack {
                    Button("后退", systemImage: "chevron.left") { session.webView.goBack() }
                    Button("前进", systemImage: "chevron.right") { session.webView.goForward() }
                    Spacer()
                    Button(session.webView.url?.host ?? "网址") {
                        addressText = session.webView.url?.absoluteString ?? ""; editingAddress = true
                    }.font(.caption).lineLimit(1)
                    Button("刷新", systemImage: "arrow.clockwise") { session.webView.reload() }
                }.labelStyle(.iconOnly).padding()
            }
            .navigationTitle(source.name ?? "WebView").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(session.busy ? "同步中…" : "完成") {
                        Task { if await session.finish() { dismiss() } }
                    }.disabled(session.busy)
                }
            }
            .alert("网页地址", isPresented: $editingAddress) {
                TextField("https://", text: $addressText).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("打开") { session.open(addressText) }
                Button("取消", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled()
        .task { await session.prepare(source: source, address: address, manga: manga) }
    }
}

@MainActor private final class SourceWebSession: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var busy = false
    @Published var error: String?
    private var hosts = Set<String>()
    private var prepared = false
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "EC3C534C-B995-45D9-98AA-60B85A63C0B7")!)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func prepare(source: MangaSource, address: URL?, manga: SourceManga?) async {
        guard !prepared else { return }; prepared = true; busy = true
        defer { busy = false }
        do {
            var arguments: [String: Any] = ["source": source.id]
            if let manga { arguments["manga"] = try SourceEngine.object(manga) }
            let info = try await SourceEngine.call("webViewInfo", arguments, as: SourceWebInfo.self)
            guard let url = address ?? URL(string: info.url), let host = url.host,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw SourceError.message("此源没有提供有效的网页地址，请检查图源设置。") }
            hosts.insert(host)
            webView.customUserAgent = info.headers.first { $0.key.lowercased() == "user-agent" }?.value
            let cookies = try await SourceEngine.call("exportCookies", ["host": host], as: [WebCookie].self)
            for item in cookies {
                var properties: [HTTPCookiePropertyKey: Any] = [.name: item.name, .value: item.value, .domain: item.domain, .path: item.path]
                if item.secure { properties[.secure] = "TRUE" }
                if item.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let expires = item.expires { properties[.expires] = Date(timeIntervalSince1970: Double(expires) / 1000) }
                if let cookie = HTTPCookie(properties: properties) { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            }
            var request = URLRequest(url: url)
            if url.host == URL(string: info.url)?.host {
                for (key, value) in info.headers where key.lowercased() != "user-agent" && key.lowercased() != "cookie" { request.setValue(value, forHTTPHeaderField: key) }
            }
            webView.load(request)
        } catch { self.error = error.localizedDescription }
    }
    func finish() async -> Bool {
        busy = true; defer { busy = false }
        do {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let values: [[String: Any]] = cookies.map { cookie in
                var value: [String: Any] = ["name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path, "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly]
                if let date = cookie.expiresDate { value["expires"] = Int64(date.timeIntervalSince1970 * 1000) }
                return value
            }
            let _: Bool = try await SourceEngine.call("cookies", ["cookies": values, "hosts": Array(hosts)], as: Bool.self)
            return true
        } catch { self.error = "登录信息同步失败：" + error.localizedDescription; return false }
    }
    func open(_ raw: String) {
        guard let url = URL(string: raw), url.host != nil, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { error = "请输入完整的 http 或 https 地址。"; return }
        error = nil; webView.load(URLRequest(url: url))
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let host = navigationAction.request.url?.host { hosts.insert(host) }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { objectWillChange.send() }
    struct WebCookie: Decodable { let name, value, domain, path: String; let secure, httpOnly: Bool; let expires: Int64? }
}
private struct SourceWebView: UIViewRepresentable {
    @ObservedObject var session: SourceWebSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ExtensionCatalogView: View {
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var query = ""
    var body: some View {
        List {
            if extensions.busy { ProgressView("正在读取仓库…") }
            if let message = extensions.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            ForEach(extensions.repositories) { repository in
                Section(repository.name) {
                    ForEach(extensions.catalog.filter { $0.repository == repository.id && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.package.localizedCaseInsensitiveContains(query)) }) { item in
                        HStack {
                            VStack(alignment: .leading) { Text(item.name); Text(item.version).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if extensions.installed.contains(where: { $0.package == item.package }) { Text("已安装").font(.caption).foregroundStyle(.secondary) }
                            else { Button("安装") { Task { await extensions.update(item) } }.disabled(extensions.busy).buttonStyle(.bordered) }
                        }
                    }
                }
            }
        }
        .navigationTitle("仓库插件")
        .searchable(text: $query, prompt: "名称或插件包名")
        .task { if extensions.catalog.isEmpty { await extensions.checkUpdates() } }
        .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await extensions.checkUpdates() } }.disabled(extensions.busy) }
    }
}
