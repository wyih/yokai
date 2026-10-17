import SwiftUI

struct StorageManagementView: View {
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var downloads: DownloadStore
    @State private var inventory: ComicStorageInventory?
    @State private var working = false
    @State private var completed = 0
    @State private var total = 1
    @State private var status = "正在统计…"
    @State private var error: String?
    @State private var result: String?
    @State private var confirmation: Cleanup?
    @State private var externalBackupPath: String?
    @State private var excludedCategories: Set<String> = []
    @State private var allowBookmarks = false

    private enum Cleanup: Identifiable {
        case book(String, String), category(String), downloads, covers, backups
        var id: String {
            switch self {
            case .book(let id, _): id
            case .category(let name): "category:" + name
            case .downloads: "downloads"
            case .covers: "covers"
            case .backups: "backups"
            }
        }
        var title: String {
            switch self {
            case .book(_, let title): "清理《\(title)》的离线章节？"
            case .category(let name): "清理“\(name.isEmpty ? "未分类" : name)”的离线章节？"
            case .downloads: "清理可移除的离线章节？"
            case .covers: "清理封面缓存？"
            case .backups: "删除较早的本机备份？"
            }
        }
        var message: String {
            switch self {
            case .book, .category, .downloads:
                "保留收藏、阅读进度、历史和书签。跳过下载队列中未完成的章节、保护分类，以及下载设置要求保留的书签章节。清理后需重新下载图片才能离线阅读。"
            case .covers:
                "清理浏览时缓存的封面，需要时会重新加载。书架封面和自定义封面保留；正在处理的临时封面文件不清理。"
            case .backups:
                "只清理本机默认目录中的自动备份，保留最新一份。当前书库、进度、书签和收藏不受影响。已删除的备份不能用于恢复。"
            }
        }
    }

    private var coverRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SourceCovers", isDirectory: true)
    }
    private var backupRoot: URL { YokaiStorage.documents.appendingPathComponent("Backups", isDirectory: true) }
    private func formatted(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private var removableChapters: Int {
        inventory?.books.reduce(0) { $0 + removable(in: $1).count } ?? 0
    }

    var body: some View {
        List {
            if working {
                Section {
                    ProgressView(value: Double(completed), total: Double(max(1, total))) {
                        Text(status).lineLimit(2)
                    }.accessibilityIdentifier("storageProgress")
                }
            }
            if let inventory {
                Section {
                    LabeledContent("漫画与本机备份", value: formatted(inventory.total)).accessibilityIdentifier("storageTotalBytes")
                    Text("按文件大小统计；不含图源插件和栖页书籍。系统显示的磁盘占用可能有所不同。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("离线章节", value: formatted(inventory.books.reduce(0) { $0 + $1.chapterBytes })).accessibilityIdentifier("storageDownloadBytes")
                    Button("清理可移除的章节（\(removableChapters) 章）", role: .destructive) { confirmation = .downloads }
                        .disabled(working || removableChapters == 0).accessibilityIdentifier("storageClearDownloads")
                    Menu("按书架分类清理") {
                        ForEach([""] + library.categoryNames, id: \.self) { category in
                            let count = inventory.books.filter { inCategory($0.id, category) }.reduce(0) { $0 + removable(in: $1).count }
                            Button("\(category.isEmpty ? "未分类" : category)（\(count) 章）", role: .destructive) { confirmation = .category(category) }
                                .disabled(count == 0)
                        }
                    }.disabled(working || removableChapters == 0).accessibilityIdentifier("storageClearCategory")
                    NavigationLink("下载保护设置") { DownloadSettingsView() }
                    Text("收藏、阅读进度、历史和书签会保留。下载中、等待或暂停等未完成任务，以及受下载设置保护的章节会跳过。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("按类别清理") }

                Section {
                    ForEach(inventory.books) { book in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(book.title).font(.headline)
                                Spacer()
                                Text(formatted(book.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            if book.imported {
                                Text("本地导入原件 · 如需移除，请在书架删除该漫画。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("\(book.chapters.count) 章 · \(book.chapters.reduce(0) { $0 + $1.pages }) 张已下载图片 · 章节文件 \(formatted(book.chapterBytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                                let removable = removable(in: book)
                                if !removable.isEmpty {
                                    Button("清理 \(removable.count) 章（\(formatted(removable.reduce(0) { $0 + $1.bytes }))）", role: .destructive) {
                                        confirmation = .book(book.id, book.title)
                                    }.disabled(working).accessibilityIdentifier("storageClearBook." + book.id)
                                } else if book.chapterBytes > 0 {
                                    Text("当前章节受保护、下载未完成或没有可清理的完整章节。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 4).accessibilityIdentifier("storageBook." + book.id)
                    }
                    if inventory.books.isEmpty { Text("书库暂无漫画").foregroundStyle(.secondary) }
                } header: { Text("按漫画查看 · 占用从大到小") }

                Section {
                    LabeledContent("浏览封面缓存", value: formatted(inventory.coverBytes)).accessibilityIdentifier("storageCoverBytes")
                    Button("清理封面缓存（\(formatted(inventory.covers.reduce(0) { $0 + $1.bytes }))）", role: .destructive) { confirmation = .covers }
                        .disabled(working || inventory.covers.isEmpty).accessibilityIdentifier("storageClearCovers")
                    Text("书架封面、自定义封面保留。尚在写入的临时封面不清理。")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("系统临时文件", value: formatted(inventory.temporaryBytes)).accessibilityIdentifier("storageTemporaryBytes")
                    Text("临时目录由导入、导出和其他模块共用，由系统管理。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("封面与临时文件") }

                Section {
                    LabeledContent("本机自动备份", value: "\(inventory.backups.count) 份 · \(formatted(inventory.backupBytes))").accessibilityIdentifier("storageBackupBytes")
                    Button("删除较早备份，保留最新一份", role: .destructive) { confirmation = .backups }
                        .disabled(working || inventory.backups.count < 2).accessibilityIdentifier("storageClearBackups")
                    if let size = inventory.externalBackupBytes {
                        LabeledContent("自选目录中的自动备份", value: formatted(size))
                        Text("自选目录可能包含其他文件，请使用“文件”管理。" + (externalBackupPath.map { "\n" + $0 } ?? ""))
                            .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("这里只统计自动备份；通过分享或导出保存到其他位置的备份由保存位置管理。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("备份") }
                if !inventory.errors.isEmpty {
                    Section("部分文件未能统计") {
                        ForEach(Array(inventory.errors.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
            }
            if let result { Section { Text(result).font(.footnote).accessibilityIdentifier("storageResult") } }
            if let error { Section("操作未完成") { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("storageError") } }
        }
        .navigationTitle("存储空间").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新", systemImage: "arrow.clockwise") { Task { await refresh() } }.disabled(working).accessibilityIdentifier("storageRefresh") }
        .refreshable { await refresh() }
        .task { await refresh() }
        .alert(confirmation?.title ?? "清理文件？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { choice in
            Button("清理", role: .destructive) { confirmation = nil; Task { await clean(choice) } }
            Button("取消", role: .cancel) { confirmation = nil }
        } message: { choice in Text(choice.message) }
    }

    private func removable(in item: ComicStorageBook) -> [ComicStorageChapter] {
        guard let book = library.books.first(where: { $0.id == item.id }), let origin = book.origin else { return [] }
        let unfinished = Set(downloads.jobs.filter { $0.sourceID == origin.sourceID && $0.manga.url == origin.mangaURL && $0.state != .completed }.map { $0.chapter.url })
        return item.chapters.filter { ComicStorage.canRemove(chapterURL: $0.url, book: book, unfinished: unfinished,
            excludedCategories: excludedCategories, allowBookmarks: allowBookmarks) }
    }

    private func inCategory(_ bookID: String, _ category: String) -> Bool {
        guard let book = library.books.first(where: { $0.id == bookID }) else { return false }
        let categories = book.categories ?? []
        return category.isEmpty ? categories.isEmpty : categories.contains(category)
    }

    @MainActor private func readProtection() {
        excludedCategories = Set(YokaiStorage.defaults.stringArray(forKey: "downloads.removeExcludedCategories") ?? [])
        allowBookmarks = YokaiStorage.defaults.bool(forKey: "downloads.removeBookmarks")
    }

    @MainActor private func refresh() async {
        guard !working else { return }
        working = true; completed = 0; total = library.books.count + 2; status = "正在统计…"; error = nil
        readProtection()
        defer { working = false }
        var scopedFolder: URL?
        var access = false
        defer { if access { scopedFolder?.stopAccessingSecurityScopedResource() } }
        if YokaiStorage.defaults.data(forKey: "backup.folder") != nil {
            do {
                let folder = try AutomaticBackups.folder()
                scopedFolder = folder.0; access = folder.1; externalBackupPath = folder.0.path
            } catch { self.error = "自选备份目录：" + error.localizedDescription }
        } else { externalBackupPath = nil }
        let books = library.books, root = library.root, covers = coverRoot, backups = backupRoot
        let external = scopedFolder, temporary = FileManager.default.temporaryDirectory
        let scan = Task.detached(priority: .utility) {
            try ComicStorage.scan(books: books, root: root, covers: covers, backups: backups, externalBackups: external, temporary: temporary) { count, name in
                Task { @MainActor in completed = count; status = "正在统计：" + name }
            }
        }
        do {
            let measured = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            inventory = measured
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    @MainActor private func clean(_ choice: Cleanup) async {
        guard !working, let measured = inventory else { return }
        working = true; error = nil; result = nil; completed = 0; status = "正在清理…"
        readProtection()
        do {
            switch choice {
            case .book, .category, .downloads:
                let selected = measured.books.filter { item in
                    if case .book(let id, _) = choice { return item.id == id }
                    if case .category(let name) = choice { return inCategory(item.id, name) }
                    return !item.imported
                }
                total = max(1, selected.reduce(0) { $0 + removable(in: $1).count })
                var removed = 0
                for item in selected {
                    // Recheck queue/protection after every suspension. Paused
                    // workers may still have in-flight image writes.
                    for chapter in item.chapters {
                        readProtection()
                        guard removable(in: item).contains(where: { $0.url == chapter.url }) else { continue }
                        try ComicStorage.validateChapter(root: library.root, bookID: item.id, chapterURL: chapter.url)
                        status = "正在清理：" + item.title
                        downloads.deleteIfAllowed(bookID: item.id, chapterURL: chapter.url)
                        let directory = library.chapterDirectory(bookID: item.id, chapterURL: chapter.url)
                        guard !FileManager.default.fileExists(atPath: directory.path) else {
                            throw SourceError.message(library.errorMessage ?? "章节未能删除，请刷新后重试。")
                        }
                        removed += 1; completed += 1
                        await Task.yield()
                    }
                }
                result = "已清理 \(removed) 个离线章节，收藏、阅读进度、历史和书签已保留。"
            case .covers, .backups:
                let files = choice.id == "covers" ? measured.covers : Array(measured.backups.dropFirst())
                let root = choice.id == "covers" ? coverRoot : backupRoot
                total = 1
                let removed = try await Task.detached(priority: .utility) { try ComicStorage.remove(files, from: root) }.value
                completed = 1
                result = "已清理 \(removed) 个文件。" + (removed < files.count ? "新写入或已变化的文件已跳过。" : "")
            }
        } catch { self.error = error.localizedDescription }
        let cleaningError = error
        working = false
        await refresh()
        if let cleaningError { error = cleaningError }
    }
}
