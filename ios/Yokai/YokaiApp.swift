import SwiftUI
import UniformTypeIdentifiers

@main
struct YokaiApp: App {
    @UIApplicationDelegateAdaptor(YokaiApplicationDelegate.self) private var appDelegate
    @StateObject private var library: ComicLibrary
    @StateObject private var sync: WebDAVSync
    @StateObject private var extensions = ExtensionStore()
    @StateObject private var downloads = DownloadStore()
    @StateObject private var activity = LibraryActivity()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accent") private var accent = "purple"
    @State private var incomingBackup: URL?
    @State private var selectedTab = 0

    init() {
        let library = ComicLibrary()
        _library = StateObject(wrappedValue: library)
        _sync = StateObject(wrappedValue: WebDAVSync(library: library))
        #if DEBUG && targetEnvironment(simulator)
        if LocalUIFixture.previewScreen == "sources" { _selectedTab = State(initialValue: 2) }
        #endif
    }
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            LibraryView().tabItem { Label("书架", systemImage: "books.vertical") }.tag(0)
            RecentsView().tabItem { Label("最近", systemImage: "clock") }.tag(1)
            SourcesView().tabItem { Label("浏览", systemImage: "safari") }.tag(2)
        }
    }
    @ViewBuilder private var content: some View {
        #if DEBUG && targetEnvironment(simulator)
        if let screen = LocalUIFixture.previewScreen, !["library", "sources"].contains(screen) {
            LocalPreviewView(screen: screen)
        } else { tabs }
        #else
        tabs
        #endif
    }
    var body: some Scene {
        WindowGroup {
            content.environmentObject(library).environmentObject(sync).environmentObject(extensions).environmentObject(downloads).environmentObject(activity)
                .tint(accent == "blue" ? .blue : accent == "green" ? .green : accent == "orange" ? .orange : .purple)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task {
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    await extensions.start(); downloads.connect(library: library, extensions: extensions)
                    #if DEBUG && targetEnvironment(simulator)
                    LocalUIFixture.checkReaderBrightness()
                    if LocalUIFixture.previewScreen != nil { try? LocalUIFixture.preparePreviewImages(library: library) }
                    if LocalUIFixture.enabled { await LocalUIFixture.checkFiles(library: library, extensions: extensions) }
                    if LocalUIFixture.enabled { await LocalUIFixture.checkDownloads(extensions: extensions) }
                    if LocalUIFixture.enabled { await LocalUIFixture.checkTachimanga(extensions: extensions) }
                    if LocalPerformanceCheck.enabled { await LocalPerformanceCheck.run() }
                    #endif
                    await AppMaintenance.perform(library: library, extensions: extensions, downloads: downloads, activity: activity)
                }
                .onOpenURL { url in Task {
                    if ["apk", "jar"].contains(url.pathExtension.lowercased()) { await extensions.start(); await extensions.importExtension(url) }
                    else if ["tachibk", "gz", "json", "tmb"].contains(url.pathExtension.lowercased()) { incomingBackup = url }
                    else { await library.importFiles([url]) }
                } }
                .sheet(isPresented: Binding(get: { incomingBackup != nil }, set: { if !$0 { incomingBackup = nil } })) {
                    NavigationStack { BackupSettingsView(incomingURL: incomingBackup).toolbar { Button("完成") { incomingBackup = nil } } }
                        .environmentObject(library).environmentObject(extensions)
                }
                .onChange(of: library.changeCount) { _, _ in sync.schedule() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        Task {
                            let background = UIApplication.shared.beginBackgroundTask(withName: "保存阅读进度")
                            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                            do { try await library.flushPendingSaves() }
                            catch { library.errorMessage = "书架保存失败：" + error.localizedDescription }
                        }
                    }
                    if phase == .active { sync.schedule(); downloads.foreground(); Task { await AppMaintenance.perform(library: library, extensions: extensions, downloads: downloads, activity: activity) } }
                    if phase == .background { downloads.beginBackground(); AppMaintenance.schedule() }
                }
        }
        .backgroundTask(.appRefresh(AppMaintenance.identifier)) {
            await AppMaintenance.perform(library: library, extensions: extensions, downloads: downloads, activity: activity)
            await AppMaintenance.schedule()
        }
    }
}

final class YokaiApplicationDelegate: NSObject, UIApplicationDelegate {
    static var readerOrientation: UIInterfaceOrientationMask = .all
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.readerOrientation
    }
}

enum ReaderOrientation {
    static func apply(_ orientation: String) {
        let mask: UIInterfaceOrientationMask = orientation == "portrait" ? .portrait : orientation == "landscape" ? .landscape : .all
        YokaiApplicationDelegate.readerOrientation = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            scene.windows.first(where: \.isKeyWindow)?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}

struct MoreView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { DownloadsView() } label: { Label("下载队列", systemImage: "arrow.down.circle") }
                    NavigationLink { BackupSettingsView() } label: { Label("备份与恢复", systemImage: "externaldrive") }
                    NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gearshape") }
                }
                Section { NavigationLink("开源许可") { LicenseView() } }
            }.navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct SettingsView: View {
    @AppStorage("readerMode") private var mode = "webtoon"
    @AppStorage("rightToLeft") private var rightToLeft = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("accent") private var accent = "purple"

    var body: some View {
            Form {
                Section("书架") {
                    NavigationLink("书架显示与筛选") { LibraryDisplaySettingsView() }
                    NavigationLink("分类") { CategoryManagerView() }
                    NavigationLink("书架更新") { LibraryUpdateSettingsView() }
                }
                Section("数据") {
                    NavigationLink("备份与恢复") { BackupSettingsView() }
                }
                Section("下载") { NavigationLink("下载设置") { DownloadSettingsView() } }
                Section("阅读") {
                    NavigationLink("阅读设置") { ReaderDefaultsView() }
                }
                Section("外观") {
                    Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                    Picker("强调色", selection: $accent) { Text("紫色").tag("purple"); Text("蓝色").tag("blue"); Text("绿色").tag("green"); Text("橙色").tag("orange") }
                }
                Section("关于") {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("支持文件", value: "CBZ / ZIP / PDF / 图片")
                    NavigationLink("开源许可") { LicenseView() }
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseView: View {
    var body: some View {
        ScrollView {
            Text((try? String(contentsOf: Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")!, encoding: .utf8)) ?? "")
                .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("开源许可")
    }
}
