import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class YokaiSession: ObservableObject {
    let library: ComicLibrary
    let sync: WebDAVSync
    let extensions = ExtensionStore()
    let downloads = DownloadStore()
    let activity = LibraryActivity()
    @Published var incomingBackup: URL?
    init() {
        #if DEBUG && targetEnvironment(macCatalyst)
        library = ComicLibrary(root: DesktopCheck.directory?.appendingPathComponent("Library"))
        #else
        library = ComicLibrary()
        #endif
        sync = WebDAVSync(library: library)
    }
    func start() async {
        #if READING_HUB && DEBUG && targetEnvironment(simulator)
        // The upstream simulator VM cannot initialize its code cache.
        // Host UI tests exercise routing here; plugins are verified on iPhone.
        if ProcessInfo.processInfo.arguments.contains("--reader-host-ui-test") { return }
        #endif
        #if !targetEnvironment(macCatalyst)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        await extensions.start(); downloads.connect(library: library, extensions: extensions)
        #if DEBUG && targetEnvironment(macCatalyst)
        await DesktopCheck.run(library: library, extensions: extensions)
        if DesktopCheck.directory != nil { return }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        LocalUIFixture.checkReaderBrightness()
        if LocalUIFixture.previewScreen != nil { try? LocalUIFixture.preparePreviewImages(library: library) }
        if LocalUIFixture.enabled { await LocalUIFixture.checkFiles(library: library, extensions: extensions); await LocalUIFixture.checkDownloads(extensions: extensions); await LocalUIFixture.checkTachimanga(extensions: extensions) }
        if LocalUIFixture.enabled { await LocalUIFixture.checkCovers(extensions: extensions) }
        if LocalPerformanceCheck.enabled { await LocalPerformanceCheck.run() }
        #endif
        await maintain()
    }
    func maintain() async {
        await AppMaintenance.perform(library: library, extensions: extensions, downloads: downloads, activity: activity)
    }
    func open(_ url: URL) async {
        guard url.isFileURL else { return }
        if ["apk", "jar"].contains(url.pathExtension.lowercased()) { await extensions.start(); await extensions.importExtension(url) }
        else if ["tachibk", "gz", "json", "tmb"].contains(url.pathExtension.lowercased()) { incomingBackup = url }
        else { await library.importFiles([url]) }
    }
    func phase(_ phase: ScenePhase) {
        if phase != .active {
            Task {
                #if !targetEnvironment(macCatalyst)
                let background = UIApplication.shared.beginBackgroundTask(withName: "保存阅读进度")
                defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                #endif
                do { try await library.flushPendingSaves() }
                catch { library.errorMessage = "书架保存失败：" + error.localizedDescription }
            }
        }
        if phase == .active { sync.schedule(); downloads.foreground(); Task { await maintain() } }
        if phase == .background { downloads.beginBackground(); AppMaintenance.schedule() }
    }
}

#if !READING_HUB
@main
struct YokaiApp: App {
    @UIApplicationDelegateAdaptor(YokaiApplicationDelegate.self) private var appDelegate
    @StateObject private var session = YokaiSession()
    var body: some Scene {
        WindowGroup { YokaiRootView(session: session) }
        #if targetEnvironment(macCatalyst)
        .commands { DesktopReaderCommands() }
        #endif
        #if !targetEnvironment(macCatalyst)
        .backgroundTask(.appRefresh(AppMaintenance.identifier)) {
            await session.maintain(); await AppMaintenance.schedule()
        }
        #endif
    }
}
#endif

struct YokaiRootView: View {
    @ObservedObject var session: YokaiSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance", store: YokaiStorage.defaults) private var appearance = "system"
    @AppStorage("accent", store: YokaiStorage.defaults) private var accent = "purple"
    @State private var selectedTab = 0
    private var tabs: some View {
        TabView(selection: $selectedTab) {
            LibraryView().tabItem { Label("书架", systemImage: "books.vertical") }.tag(0)
            RecentsView().tabItem { Label("最近", systemImage: "clock") }.tag(1)
            SourcesView().tabItem { Label("浏览", systemImage: "safari") }.tag(2)
        }
    }
    @ViewBuilder private var content: some View {
        #if DEBUG && targetEnvironment(simulator)
        if let screen = LocalUIFixture.previewScreen, !["library", "sources"].contains(screen) { LocalPreviewView(screen: screen) }
        else { tabs }
        #else
        tabs
        #endif
    }
    var body: some View {
        content.environmentObject(session.library).environmentObject(session.sync).environmentObject(session.extensions).environmentObject(session.downloads).environmentObject(session.activity)
            .tint(accent == "blue" ? .blue : accent == "green" ? .green : accent == "orange" ? .orange : .purple)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .task {
                #if DEBUG && targetEnvironment(simulator)
                if LocalUIFixture.previewScreen == "sources" { selectedTab = 2 }
                #endif
                await session.start()
                #if targetEnvironment(macCatalyst)
                for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                    scene.sizeRestrictions?.minimumSize = CGSize(width: 760, height: 560)
                }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(300)) } catch { break }
                    await session.maintain()
                }
                #endif
            }
            #if !READING_HUB
            .onOpenURL { url in Task { await session.open(url) } }
            .onChange(of: scenePhase) { _, phase in session.phase(phase) }
            #endif
            .sheet(isPresented: Binding(get: { session.incomingBackup != nil }, set: { if !$0 { session.incomingBackup = nil } })) {
                NavigationStack { BackupSettingsView(incomingURL: session.incomingBackup).toolbar { Button("完成") { session.incomingBackup = nil } } }
                    .environmentObject(session.library).environmentObject(session.extensions)
            }
            .onChange(of: session.library.changeCount) { _, _ in session.sync.schedule() }
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
        #if !targetEnvironment(macCatalyst)
        let mask: UIInterfaceOrientationMask = orientation == "portrait" ? .portrait : orientation == "landscape" ? .landscape : .all
        YokaiApplicationDelegate.readerOrientation = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            scene.windows.first(where: \.isKeyWindow)?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
        #endif
    }
}

struct MoreView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                #if READING_HUB
                Section {
                    Button("切换阅读器", systemImage: "square.grid.2x2") {
                        dismiss()
                        NotificationCenter.default.post(name: Notification.Name("ReadingHubHome"), object: nil)
                    }
                }
                #endif
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
    @AppStorage("readerMode", store: YokaiStorage.defaults) private var mode = "webtoon"
    @AppStorage("rightToLeft", store: YokaiStorage.defaults) private var rightToLeft = true
    @AppStorage("appearance", store: YokaiStorage.defaults) private var appearance = "system"
    @AppStorage("accent", store: YokaiStorage.defaults) private var accent = "purple"

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
