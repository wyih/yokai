import Foundation
import Security
import SwiftUI

enum DAVPassword {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.wyih.yokai.webdav", kSecAttrAccount as String: "password"]

    static func read() -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ password: String) throws {
        let value = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SyncError.keychain(status) }
    }
}

@MainActor
final class WebDAVSync: ObservableObject {
    @Published private(set) var configuration = DAVConfiguration()
    @Published private(set) var running = false
    @Published private(set) var lastSync: Date?
    @Published var message: String?
    @Published var conflicts: [ProgressConflict] = []
    private var choices: [String: ProgressChoice] = [:]
    private var baselines: [String: String] = [:]
    private let library: ComicLibrary
    private var pending: Task<Void, Never>?

    init(library: ComicLibrary) {
        self.library = library
        let defaults = YokaiStorage.defaults
        if let data = defaults.data(forKey: "webdavConfiguration"),
           let stored = try? JSONDecoder().decode(DAVConfiguration.self, from: data) { configuration = stored }
        if let data = defaults.data(forKey: "webdavBaseline"),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) { baselines = stored }
        lastSync = defaults.object(forKey: "webdavLastSync") as? Date
    }

    func connect(_ candidate: DAVConfiguration, password: String) async throws {
        let sameAccount = candidate.url == configuration.url && candidate.username == configuration.username
        let secret = password.isEmpty && sameAccount ? DAVPassword.read() : password
        _ = try await DAVClient(configuration: candidate, password: secret).prepare()
        try DAVPassword.write(secret)
        if candidate.identity != configuration.identity { baselines = [:]; choices = [:]; conflicts = []; lastSync = nil }
        configuration = candidate
        let defaults = YokaiStorage.defaults
        defaults.set(try JSONEncoder().encode(candidate), forKey: "webdavConfiguration")
        defaults.set(try JSONEncoder().encode(baselines), forKey: "webdavBaseline")
        defaults.set(lastSync, forKey: "webdavLastSync")
    }

    func schedule() {
        guard configuration.automatic, !configuration.url.isEmpty else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await synchronize()
        }
    }

    func choose(local: Bool, id: String) {
        guard let conflict = conflicts.first(where: { $0.id == id }) else { return }
        choices[id] = ProgressChoice(conflict: conflict, keepLocal: local)
        conflicts.removeAll { $0.id == id }
        if conflicts.isEmpty { Task { await synchronize() } }
    }

    func synchronize() async {
        guard !running, !configuration.url.isEmpty else { return }
        running = true
        defer { running = false }
        do {
            let client = DAVClient(configuration: configuration, password: DAVPassword.read())
            let url = try await client.prepare()
            for _ in 0..<3 {
                let (remote, etag) = try await client.read(url)
                let captured = library.snapshot()
                let result = ShelfMerge.merge(local: captured, remote: remote, baseline: baselines, choices: choices)
                if !result.conflicts.isEmpty { conflicts = result.conflicts; return }
                if etag == nil || result.state != remote {
                    if !(try await client.write(result.state, to: url, etag: etag)) { continue }
                }
                baselines = Dictionary(uniqueKeysWithValues: result.state.books.map { ($0.id, $0.progressRevision) })
                library.acceptSync(result.state, captured: captured)
                choices = [:]
                lastSync = Date()
                YokaiStorage.defaults.set(try JSONEncoder().encode(baselines), forKey: "webdavBaseline")
                YokaiStorage.defaults.set(lastSync, forKey: "webdavLastSync")
                message = nil
                return
            }
            throw SyncError.conflict
        } catch { message = error.localizedDescription }
    }
}

struct WebDAVSettingsView: View {
    @EnvironmentObject private var sync: WebDAVSync
    @State private var draft = DAVConfiguration()
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("连接设置") {
                TextField("HTTPS WebDAV 地址", text: $draft.url).textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("用户名", text: $draft.username).textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码（留空沿用现有密码）", text: $password).textContentType(.password)
                TextField("个人目录，例如 personal/小明", text: $draft.directory)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("自动同步", isOn: $draft.automatic)
                Button(connecting ? "正在验证…" : "验证并保存") {
                    connecting = true
                    Task {
                        do { try await sync.connect(draft, password: password); password = ""; error = nil; await sync.synchronize() }
                        catch { self.error = error.localizedDescription }
                        connecting = false
                    }
                }.disabled(connecting || sync.running)
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            if !sync.configuration.url.isEmpty {
                Section("同步") {
                    if let date = sync.lastSync { LabeledContent("上次同步") { Text(date, style: .relative) } }
                    Button(sync.running ? "正在同步…" : "立即同步") { Task { await sync.synchronize() } }
                        .disabled(sync.running || connecting)
                    if let message = sync.message { Text(message).foregroundStyle(.red).font(.footnote) }
                    ForEach(sync.conflicts) { conflict in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(conflict.local.title).font(.headline)
                            Text("两台设备的阅读位置发生变化，请选择保留的位置。")
                            Button("本机：\(conflict.local.origin?.chapterTitle ?? "") 第 \(conflict.local.lastPage + 1) 页") { sync.choose(local: true, id: conflict.id) }
                            Button("云端：\(conflict.remote.origin?.chapterTitle ?? "") 第 \(conflict.remote.lastPage + 1) 页") { sync.choose(local: false, id: conflict.id) }
                        }
                    }
                }
            }
            Section {
                Text("同步书架、章节、阅读位置和书签。在线漫画通过同一图源继续阅读；本地漫画在其他设备导入相同文件后自动匹配。远端目录：个人目录 / Yokai / sync。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("WebDAV 同步").navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = sync.configuration }
    }
}
