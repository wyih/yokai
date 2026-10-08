import SwiftUI
import BackgroundTasks

@MainActor
enum AppMaintenance {
    static let identifier = "com.wyih.yokai.refresh"
    private static var running = false
    static func perform(library: ComicLibrary, extensions: ExtensionStore, downloads: DownloadStore, activity: LibraryActivity) async {
        #if DEBUG && targetEnvironment(simulator)
        if LocalUIFixture.enabled { return }
        #endif
        guard !running else { return }; running = true; defer { running = false }
        await extensions.start()
        guard !extensions.busy else { return }
        downloads.connect(library: library, extensions: extensions)
        if Task.isCancelled { return }
        let defaults = UserDefaults.standard
        let hours = defaults.object(forKey: "library.updateHours") as? Int ?? 24
        let charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        if hours > 0, Date().timeIntervalSince(activity.checkedAt ?? .distantPast) >= Double(hours) * 3600,
           (!defaults.bool(forKey: "library.updateWifi") || downloads.wifi),
           (!defaults.bool(forKey: "library.updateCharging") || charging) {
            await activity.refresh(library: library, extensions: extensions, downloads: downloads, automatic: true)
        }
        if Task.isCancelled { return }
        await extensions.automaticUpdatesIfDue()
        if Task.isCancelled { return }
        await AutomaticBackups.createIfDue(library: library, extensions: extensions)
    }
    static func schedule() {
        let defaults = UserDefaults.standard
        let periods = [defaults.object(forKey: "library.updateHours") as? Int ?? 24, defaults.integer(forKey: "backup.hours"), defaults.bool(forKey: "extensions.autoCheck") ? 24 : 0].filter { $0 > 0 }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let hours = periods.min() else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Double(hours) * 3600)
        do { try BGTaskScheduler.shared.submit(request); defaults.removeObject(forKey: "maintenance.error") }
        catch { defaults.set(error.localizedDescription, forKey: "maintenance.error") }
    }
}

@MainActor
enum AutomaticBackups {
    static func folder() throws -> (URL, Bool) {
        if let bookmark = UserDefaults.standard.data(forKey: "backup.folder") {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
            let access = url.startAccessingSecurityScopedResource()
            if stale { UserDefaults.standard.set(try url.bookmarkData(), forKey: "backup.folder") }
            return (url, access)
        }
        return (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Backups"), false)
    }
    static func createIfDue(library: ComicLibrary, extensions: ExtensionStore, force: Bool = false) async {
        let defaults = UserDefaults.standard, hours = UserDefaults.standard.integer(forKey: "backup.hours")
        guard force || (hours > 0 && Date().timeIntervalSince(defaults.object(forKey: "backup.lastCreated") as? Date ?? .distantPast) >= Double(hours) * 3600) else { return }
        guard !library.books.isEmpty || !library.categories.isEmpty else { return }
        do {
            let (folder, access) = try folder()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let exported = try await AndroidBackupService.export(library: library, extensions: extensions, appPreferences: true, sourcePreferences: true)
            defer { try? FileManager.default.removeItem(at: exported) }
            let destination = folder.appendingPathComponent(exported.lastPathComponent)
            try Data(contentsOf: exported).write(to: destination, options: .atomic)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("yokai_") && $0.pathExtension == "tachibk" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            let keep = max(1, defaults.object(forKey: "backup.keep") as? Int ?? 5)
            for old in files.dropFirst(keep) { try FileManager.default.removeItem(at: old) }
            defaults.set(Date(), forKey: "backup.lastCreated"); defaults.removeObject(forKey: "backup.error")
        } catch { defaults.set(error.localizedDescription, forKey: "backup.error") }
    }
}

struct CategoryPreferencePicker: View {
    let title: String
    let key: String
    @EnvironmentObject private var library: ComicLibrary
    @State private var selected: [String] = []
    var body: some View {
        NavigationLink(title) {
            List {
                ForEach(library.categoryNames, id: \.self) { category in
                    Toggle(category, isOn: Binding(get: { selected.contains(category) }, set: { enabled in
                        if enabled { selected.append(category) } else { selected.removeAll { $0 == category } }
                        UserDefaults.standard.set(selected, forKey: key)
                    }))
                }
                if library.categoryNames.isEmpty { Text("尚未创建分类").foregroundStyle(.secondary) }
            }.navigationTitle(title)
        }.task { selected = UserDefaults.standard.stringArray(forKey: key) ?? [] }
    }
}

struct LibraryUpdateSettingsView: View {
    @AppStorage("library.updateHours") private var hours = 24
    @AppStorage("library.updateWifi") private var wifi = false
    @AppStorage("library.updateCharging") private var charging = false
    @AppStorage("library.skipCompleted") private var completed = false
    @AppStorage("library.skipUnread") private var unread = false
    @AppStorage("maintenance.error") private var error = ""
    var body: some View {
        Form {
            Section("自动更新") {
                Picker("检查间隔", selection: $hours) { Text("手动").tag(0); ForEach([12, 24, 48, 72, 168], id: \.self) { Text("\($0) 小时").tag($0) } }
                Toggle("仅在 Wi-Fi 下更新", isOn: $wifi); Toggle("仅在充电时更新", isOn: $charging)
                Text("后台检查时间由 iOS 安排。打开 App 时也会检查到期的任务。").font(.footnote).foregroundStyle(.secondary)
                if !error.isEmpty { Text("后台调度：" + error).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("更新范围") {
                CategoryPreferencePicker(title: "仅更新这些分类", key: "library.updateCategories")
                CategoryPreferencePicker(title: "排除分类", key: "library.updateExcludedCategories")
                Toggle("跳过已完结漫画", isOn: $completed); Toggle("跳过从未阅读的漫画", isOn: $unread)
            }
        }.navigationTitle("书架更新").onDisappear { AppMaintenance.schedule() }
    }
}

struct AutomaticBackupSettingsView: View {
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var extensions: ExtensionStore
    @AppStorage("backup.hours") private var hours = 0
    @AppStorage("backup.keep") private var keep = 5
    @AppStorage("backup.error") private var error = ""
    @State private var choosingFolder = false
    @State private var path = "本机 / Yōkai / Backups"
    @State private var working = false
    @State private var date: Date?
    var body: some View {
        Form {
            Picker("备份间隔", selection: $hours) { Text("关闭").tag(0); ForEach([6, 12, 24, 48, 168], id: \.self) { Text("\($0) 小时").tag($0) } }
            Stepper("保留 \(keep) 份备份", value: $keep, in: 1...30)
            Button("备份目录") { choosingFolder = true }
            Text(path).font(.footnote).foregroundStyle(.secondary)
            Button("使用本机默认目录") { UserDefaults.standard.removeObject(forKey: "backup.folder"); path = "本机 / Yōkai / Backups" }
            Button("立即备份") { Task { working = true; await extensions.start(); await AutomaticBackups.createIfDue(library: library, extensions: extensions, force: true); date = UserDefaults.standard.object(forKey: "backup.lastCreated") as? Date; working = false } }.disabled(working)
            if working { ProgressView() }
            if let date { LabeledContent("最近备份", value: date.formatted()) }
            if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
            Text("自动备份使用安卓格式，包含图源设置。后台执行时间由 iOS 安排。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("自动备份")
        .task { date = UserDefaults.standard.object(forKey: "backup.lastCreated") as? Date; if let (folder, access) = try? AutomaticBackups.folder() { path = folder.path; if access { folder.stopAccessingSecurityScopedResource() } } }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do { let url = try result.get(), access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; UserDefaults.standard.set(try url.bookmarkData(), forKey: "backup.folder"); path = url.path }
            catch { self.error = error.localizedDescription }
        }.onDisappear { AppMaintenance.schedule() }
    }
}
