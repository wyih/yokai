import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct ShelfBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .data] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupSettingsView: View {
    var incomingURL: URL? = nil
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @State private var exporting = false
    @State private var importing = false
    @State private var backup = ShelfBackupDocument()
    @State private var error: String?
    @State private var restored = false
    @State private var working = false
    @AppStorage("backup.format") private var format = "android"
    @State private var appPreferences = true
    @State private var sourcePreferences = true
    @State private var exportName = "Yokai"
    private var contentType: UTType { format == "json" ? .json : UTType(filenameExtension: "tachibk") ?? .data }
    var body: some View {
        Form {
            Section("同步") {
                NavigationLink { WebDAVSettingsView() } label: { Label("WebDAV 同步", systemImage: "arrow.triangle.2.circlepath") }
                Text("在设备之间同步书架、章节进度和书签。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("本机备份") {
                NavigationLink("自动备份") { AutomaticBackupSettingsView() }
                if let incomingURL {
                    LabeledContent("待恢复的备份", value: incomingURL.lastPathComponent)
                    Button("恢复这份备份") { Task { await restore(incomingURL) } }.disabled(working)
                }
                Picker("备份格式", selection: $format) { Text("安卓 Yōkai (.tachibk)").tag("android"); Text("iOS (.json)").tag("json") }
                Toggle("包含应用设置", isOn: $appPreferences)
                Toggle("包含图源设置", isOn: $sourcePreferences)
                Button("创建备份", systemImage: "square.and.arrow.up") {
                    Task {
                        working = true; defer { working = false }
                        do {
                            if format == "android" {
                                await extensions.start()
                                let file = try await AndroidBackupService.export(library: library, extensions: extensions, appPreferences: appPreferences, sourcePreferences: sourcePreferences)
                                backup = ShelfBackupDocument(data: try Data(contentsOf: file)); exportName = file.deletingPathExtension().lastPathComponent
                                try? FileManager.default.removeItem(at: file)
                            } else { backup = ShelfBackupDocument(data: try await NativeBackup.export(library: library, extensions: extensions, appPreferences: appPreferences, sourcePreferences: sourcePreferences)); exportName = "Yokai-\(Date().formatted(.iso8601.year().month().day()))" }
                            exporting = true
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(working)
                Button("恢复备份", systemImage: "square.and.arrow.down") { importing = true }.disabled(working)
                if working { ProgressView("正在处理备份…") }
                Text("支持导入安卓 Yōkai (.tachibk)、Tachimanga (.tmb) 和 iOS (.json) 备份。恢复书架、分类、章节进度、书签和历史；漫画图片需要另行导入或下载。图源设置可能包含登录信息。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: backup, contentType: contentType, defaultFilename: exportName) { result in
            if case .failure(let error) = result { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $importing) {
            BackupImportPicker { url in
                importing = false
                if let url {
                    Task {
                        defer { try? FileManager.default.removeItem(at: url) }
                        await restore(url)
                    }
                }
            }
        }
        .alert("恢复完成", isPresented: $restored) { Button("好", role: .cancel) {} } message: { Text("已合并备份中的书架、分类、章节进度、书签和历史，保留已有的已读章节和书签。") }
        .alert("备份失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }
    private func restore(_ url: URL) async {
        working = true; defer { working = false }
        do {
            try await AndroidBackupService.restore(url, library: library, extensions: extensions, appPreferences: appPreferences, sourcePreferences: sourcePreferences)
            restored = true
        } catch { self.error = error.localizedDescription }
    }

}

private struct BackupImportPicker: UIViewControllerRepresentable {
    let selected: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Copying supports providers that cannot grant an in-place URL to a
        // LiveContainer guest. Format validation stays in the restore service.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL?) -> Void
        init(selected: @escaping (URL?) -> Void) { self.selected = selected }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
    }
}
