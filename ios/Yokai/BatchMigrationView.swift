import SwiftUI

struct BatchMigrationView: View {
    let books: [ComicBook]
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID = ""
    @State private var started = false
    @State private var active: ComicBook?
    @State private var states: [String: MigrationSearchUpdate] = [:]
    private var source: MangaSource? { extensions.sources.first { $0.id == sourceID && $0.error == nil } }
    private var completed: [ComicBook] {
        books.compactMap { if case .migrated(let result) = states[$0.id] { return result }; return nil }
    }
    private var skippedCount: Int { books.filter { if case .skipped = states[$0.id] { return true }; return false }.count }
    private var failedCount: Int { books.filter { if case .failed = states[$0.id] { return true }; return false }.count }
    private var remaining: [ComicBook] {
        books.filter {
            switch states[$0.id] {
            case .migrated, .skipped: false
            default: true
            }
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if started { LabeledContent("目标图源", value: source?.name ?? sourceID) }
                    else {
                        Picker("目标图源", selection: $sourceID) {
                            Text("选择图源").tag("")
                            ForEach(extensions.sources.filter { $0.error == nil }) { source in
                                Text(source.name ?? source.package).tag(source.id)
                            }
                        }.accessibilityIdentifier("batchMigrationSource")
                    }
                    Text("逐本搜索并确认匹配，完成的迁移立即保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if started {
                        Text("完成 \(completed.count) · 跳过 \(skippedCount) · 失败 \(failedCount) · 待处理 \(remaining.count - failedCount)")
                            .accessibilityIdentifier("batchMigrationSummary")
                        if let next = remaining.first {
                            Button("继续下一本") { open(next) }.disabled(source == nil)
                                .accessibilityIdentifier("batchMigrationContinue")
                        }
                        if source == nil { Text("目标图源已不可用，请关闭本批次并重新选择。已完成的迁移会保留。").foregroundStyle(.red) }
                    } else {
                        Button("开始批量换源") { start() }.disabled(source == nil)
                            .accessibilityIdentifier("batchMigrationStart")
                    }
                }
                Section("本批次 · \(books.count) 本") {
                    ForEach(books) { book in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(book.title).font(.headline)
                            Text(status(book)).font(.subheadline).foregroundStyle(.secondary)
                            if started {
                                switch states[book.id] {
                                case .migrated(let destination):
                                    Text("已迁移至：" + destination.title).font(.caption)
                                    if library.books.first(where: { $0.id == book.id })?.inLibrary != false {
                                        Text("原漫画已保留在书架。").font(.caption)
                                    }
                                default:
                                    if eligible(book) {
                                        HStack {
                                            Button(actionTitle(book)) { open(book) }.buttonStyle(.bordered).disabled(source == nil)
                                                .accessibilityIdentifier("batchMigrationOpen." + book.id)
                                            if case .skipped = states[book.id] {} else {
                                                Button("跳过") { states[book.id] = .skipped }.buttonStyle(.bordered)
                                                    .accessibilityIdentifier("batchMigrationSkip." + book.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("批量换源").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .navigationDestination(isPresented: Binding(get: { active != nil }, set: { if !$0 { active = nil } })) {
                if let book = active { MigrationSearchView(original: book, targetSourceID: sourceID,
                    unavailableDestinationIDs: Set(books.map(\.id) + completed.map(\.id)).subtracting([book.id]),
                    onUpdate: { update in
                        states[book.id] = update
                        switch update {
                        case .migrated, .skipped: if active?.id == book.id { active = nil }
                        default: break
                        }
                    }) }
            }
        }.interactiveDismissDisabled(active != nil)
    }
    private func eligible(_ book: ComicBook) -> Bool {
        book.origin != nil && book.origin?.sourceID != sourceID
    }
    private func start() {
        guard source != nil else { return }; started = true
        for book in books where !eligible(book) { states[book.id] = .skipped }
        if let first = remaining.first { open(first) }
    }
    private func open(_ book: ComicBook) {
        guard source != nil else { return }
        guard let latest = library.books.first(where: { $0.id == book.id }) else {
            states[book.id] = .failed("原漫画已不在本地书库中。"); return
        }
        active = latest
    }
    private func actionTitle(_ book: ComicBook) -> String {
        switch states[book.id] {
        case .failed: "重试"
        case .skipped: "重新处理"
        case .matches: "查看匹配"
        default: "搜索匹配"
        }
    }
    private func status(_ book: ComicBook) -> String {
        if book.origin == nil { return "本地漫画，跳过换源" }
        if started && book.origin?.sourceID == sourceID { return "已使用目标图源，跳过换源" }
        switch states[book.id] {
        case .searching: return active?.id == book.id ? "正在搜索" : "等待继续"
        case .matches(let count): return count == 0 ? "没有搜索结果，可修改名称重试" : "找到 \(count) 个结果，等待确认"
        case .failed(let message): return "失败：" + message
        case .migrated: return "已完成"
        case .skipped: return "已跳过"
        case nil: return "等待搜索"
        }
    }
}
