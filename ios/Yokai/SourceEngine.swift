import Foundation

enum SourceEngine {
    static func call<T: Decodable>(_ action: String, _ arguments: [String: Any] = [:], as type: T.Type) async throws -> T {
        #if DEBUG && targetEnvironment(simulator)
        if LocalUIFixture.enabled {
            let value = try await LocalUIFixture.response(action, arguments)
            return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
        #endif
        var request = arguments
        request["action"] = action
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response: String = try await withCheckedThrowingContinuation { continuation in
            JavaBridge.execute(text) { result, error in
                if let error { continuation.resume(throwing: error) }
                else if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: SourceError.message("插件未返回结果。")) }
            }
        }
        let object = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
        if let error = object?["error"] as? String { throw SourceError.message(error) }
        guard let value = object?["value"] else { throw SourceError.message("插件返回的数据无法读取。") }
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
}

enum SourceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct MangaSource: Codable, Identifiable {
    var id: String { sourceID ?? package }
    let sourceID: String?
    let name: String?
    let lang: String?
    let latest: Bool?
    let baseURL: String?
    let package: String
    let error: String?
    enum CodingKeys: String, CodingKey { case sourceID = "id", name, lang, latest, baseURL, package, error }
}

struct SourceManga: Codable, Identifiable, Equatable {
    var id: String { url }
    var url: String
    var title: String
    var thumbnail: String?
    var author: String?
    var artist: String?
    var description: String?
    var genre: String?
    var status: Int?
    var memo: String?
}
struct SourceChapter: Codable, Identifiable, Equatable {
    var id: String { url }
    var url: String
    var name: String
    var number: Double
    var uploaded: Int64
    var memo: String?
}
struct SourcePage: Codable, Identifiable {
    var id: Int { index }
    let index: Int
    let url: String?
    let imageURL: String?
}
struct SourceResults: Decodable { let manga: [SourceManga]; let hasNext: Bool }
struct SourceDetails: Codable, Equatable { let manga: SourceManga; let chapters: [SourceChapter] }
struct SourceWebInfo: Decodable { let url: String; let headers: [String: String] }

struct InstalledExtension: Codable, Identifiable {
    var id: String { package }
    let package: String
    var className: String
    var version: String
    var versionCode: String
    var file: String
    var repository: String?
}
private struct ArtifactInfo: Decodable { let package, className, version, versionCode: String }

struct ExtensionRepository: Codable, Identifiable {
    var id: String { url }
    let name: String
    let url: String
    let catalogURL: String
}
struct RepositoryExtension: Identifiable {
    var id: String { package }
    let package, name, version, versionCode: String
    let download: URL
    let repository: String
}

@MainActor
final class ExtensionStore: ObservableObject {
    @Published private(set) var installed: [InstalledExtension] = []
    @Published private(set) var sources: [MangaSource] = []
    @Published private(set) var busy = false
    @Published var message: String?
    @Published private(set) var updates: [RepositoryExtension] = []
    @Published private(set) var catalog: [RepositoryExtension] = []
    @Published private(set) var repositories: [ExtensionRepository]
    let root: URL
    private let metadata: URL
    private var started = false

    init() {
        let data = try? Data(contentsOf: Bundle.main.url(forResource: "ExtensionRepositories", withExtension: "json")!)
        let saved = UserDefaults.standard.data(forKey: "extension.repositories")
        repositories = (saved ?? data).flatMap { try? JSONDecoder().decode([ExtensionRepository].self, from: $0) } ?? []
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Extensions", isDirectory: true)
        metadata = root.appendingPathComponent("installed.json")
    }

    func start() async {
        guard !started else { return }
        started = true
        busy = true
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: metadata.path) {
                installed = try JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: metadata))
            } else {
                installed = try JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: Bundle.main.url(forResource: "BundledExtensions", withExtension: "json")!))
                for item in installed {
                    let source = Bundle.main.bundleURL.appendingPathComponent("Extensions/\(item.file)")
                    let target = root.appendingPathComponent(item.file)
                    if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
                }
                try save()
            }
            try await load()
        } catch { message = error.localizedDescription; started = false }
    }

    private func load(_ records: [InstalledExtension]? = nil) async throws {
        let items: [[String: Any]] = (records ?? installed).map { ["path": root.appendingPathComponent($0.file).path, "package": $0.package, "className": $0.className] }
        let result = try await SourceEngine.call("load", ["dataPath": root.path, "extensions": items], as: [MangaSource].self)
        if records != nil, let failure = result.first(where: { $0.error != nil }) {
            throw SourceError.message(failure.error ?? "插件加载失败。")
        }
        sources = result
    }
    private func save() throws { try JSONEncoder().encode(installed).write(to: metadata, options: .atomic) }

    func reloadPreferences() async throws { try await load() }

    func addRepository(name: String, address: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil,
              ["json", "pb"].contains(url.pathExtension) else { message = "请填写 HTTPS 扩展仓库索引地址（index.min.json 或 index.pb）。"; return }
        guard !repositories.contains(where: { $0.url == url.absoluteString }) else { message = "此仓库已添加。"; return }
        let catalog = url.pathExtension == "pb" ? url.deletingLastPathComponent().appendingPathComponent("index.min.json").absoluteString : url.absoluteString
        repositories.append(ExtensionRepository(name: name.isEmpty ? url.host! : name, url: url.absoluteString, catalogURL: catalog)); saveRepositories()
    }
    func removeRepository(_ id: String) { repositories.removeAll { $0.id == id }; catalog.removeAll { $0.repository == id }; updates.removeAll { $0.repository == id }; saveRepositories() }
    private func saveRepositories() { if let data = try? JSONEncoder().encode(repositories) { UserDefaults.standard.set(data, forKey: "extension.repositories") } }
    func uninstall(_ package: String) async {
        guard !busy, let extensionFile = installed.first(where: { $0.package == package }) else { return }
        busy = true; defer { busy = false }
        let old = installed, candidate = old.filter { $0.package != package }
        do {
            try await load(candidate); try JSONEncoder().encode(candidate).write(to: metadata, options: .atomic)
            installed = candidate; updates.removeAll { $0.package == package }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(extensionFile.file))
        } catch { try? await load(old); message = error.localizedDescription }
    }

    func automaticUpdatesIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "extensions.autoCheck"), !busy,
              Date().timeIntervalSince(defaults.object(forKey: "extensions.lastCheck") as? Date ?? .distantPast) >= 86400 else { return }
        await checkUpdates(); defaults.set(Date(), forKey: "extensions.lastCheck")
        if defaults.bool(forKey: "extensions.autoInstall") { for update in updates { await self.update(update) } }
    }

    func importExtension(_ input: URL, repository: String? = nil, catalog: RepositoryExtension? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let accessed = input.startAccessingSecurityScopedResource()
        defer { if accessed { input.stopAccessingSecurityScopedResource() } }
        let temporary = root.appendingPathComponent(UUID().uuidString + ".jar")
        do {
            let info = try await SourceEngine.call("inspect", ["input": input.path, "output": temporary.path], as: ArtifactInfo.self)
            guard info.package.range(of: "^[A-Za-z0-9_.]+$", options: .regularExpression) != nil,
                  catalog == nil || info.package == catalog?.package else { throw SourceError.message("下载的插件与仓库信息不匹配。") }
            let _: Bool = try await SourceEngine.call("validateArtifact", ["dataPath": root.path, "path": temporary.path, "className": info.className], as: Bool.self)
            let old = installed
            let previous = old.first { $0.package == info.package }
            let record = InstalledExtension(package: info.package, className: info.className,
                version: catalog?.version ?? info.version, versionCode: catalog?.versionCode ?? info.versionCode,
                file: temporary.lastPathComponent, repository: repository ?? previous?.repository)
            let candidate = old.filter { $0.package != info.package } + [record]
            do {
                try await load(candidate)
                try JSONEncoder().encode(candidate).write(to: metadata, options: .atomic)
                installed = candidate
            } catch {
                try? await load(old)
                throw error
            }
            if let previous { try? FileManager.default.removeItem(at: root.appendingPathComponent(previous.file)) }
            updates.removeAll { $0.package == info.package }
            message = "已安装 \(catalog?.name ?? info.package) \(record.version)。"
        } catch { try? FileManager.default.removeItem(at: temporary); message = error.localizedDescription }
    }

    func checkUpdates() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var available: [RepositoryExtension] = [], all: [RepositoryExtension] = [], failures: [String] = []
        for repository in repositories {
            do {
                let (url, entries) = try await repositoryEntries(repository)
                for entry in entries {
                    guard let package = (entry["packageName"] ?? entry["pkg"]) as? String else { continue }
                    let version = (entry["versionName"] ?? entry["version"]) as? String ?? ""
                    let code = String(describing: entry["versionCode"] ?? entry["code"] ?? "0")
                    let resources = entry["resources"] as? [String: Any]
                    let address: URL?
                    if let raw = (resources?["jarUrl"] ?? resources?["apkUrl"]) as? String { address = URL(string: raw) }
                    else if let apk = entry["apk"] as? String { address = url.deletingLastPathComponent().appendingPathComponent("apk").appendingPathComponent(apk) }
                    else { address = nil }
                    guard let address, address.scheme == "https" else { continue }
                    let item = RepositoryExtension(package: package, name: entry["name"] as? String ?? package,
                        version: version, versionCode: code, download: address, repository: repository.id)
                    all.append(item)
                    if let old = installed.first(where: { $0.package == package && $0.repository == repository.id }),
                       (Int(code) ?? 0) > (Int(old.versionCode) ?? 0) { available.append(item) }
                }
            } catch { failures.append(repository.name + "：" + error.localizedDescription) }
        }
        updates = available
        catalog = all
        let untracked = installed.filter { $0.repository == nil }.count
        message = failures.isEmpty ? (updates.isEmpty ? "已关联仓库的插件暂无更新。" : "发现 \(updates.count) 个插件更新。") : failures.joined(separator: "\n")
        if untracked > 0 { message = (message ?? "") + "\n\(untracked) 个本地插件尚未关联更新仓库。" }
    }

    private func repositoryEntries(_ repository: ExtensionRepository) async throws -> (URL, [[String: Any]]) {
        if let url = URL(string: repository.url), url.pathExtension == "pb" {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceError.message("仓库暂时无法访问。") }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pb")
                try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
                let parsed = try await SourceEngine.call("readRepositoryIndex", ["path": file.path], as: String.self)
                let entries = try JSONSerialization.jsonObject(with: Data(parsed.utf8)) as? [[String: Any]] ?? []
                return (url, entries)
            } catch { /* Keep the original JSON fallback for legacy repositories. */ }
        }
        guard let url = URL(string: repository.catalogURL) else { throw SourceError.message("扩展仓库地址无效。") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceError.message("仓库暂时无法访问。") }
        let parsed = try JSONSerialization.jsonObject(with: data)
        let entries = (parsed as? [[String: Any]]) ?? (((parsed as? [String: Any])?["extensionList"] as? [String: Any])?["extensions"] as? [[String: Any]]) ?? []
        guard !entries.isEmpty else { throw SourceError.message("扩展索引中没有可安装的插件。") }
        return (url, entries)
    }

    func update(_ item: RepositoryExtension) async {
        guard !busy else { return }
        busy = true
        let input = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(item.download.pathExtension)
        do {
            let (data, response) = try await URLSession.shared.data(from: item.download)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SourceError.message("插件下载失败，原有版本保留。") }
            try data.write(to: input, options: .atomic)
            busy = false
            await importExtension(input, repository: item.repository, catalog: item)
        } catch { busy = false; message = error.localizedDescription }
        try? FileManager.default.removeItem(at: input)
    }
}
