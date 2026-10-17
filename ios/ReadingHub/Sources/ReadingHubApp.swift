import SwiftUI
import UIKit
import Combine
import BackgroundTasks
import QiyeModule

@MainActor
final class HubRouter: ObservableObject {
    @Published var module: ReaderModule?
    @Published private(set) var scenePhase: ScenePhase = .inactive
    @Published var incomingFile: URL?
    private var comicSession: YokaiSession?
    private var bookModule: QiyeReaderModule?
    var comics: YokaiSession {
        if let comicSession { return comicSession }
        let value = YokaiSession(); comicSession = value; return value
    }
    var books: QiyeReaderModule {
        if let bookModule { return bookModule }
        let value = QiyeReaderModule(); bookModule = value; return value
    }
    func show(_ next: ReaderModule?) {
        if module == .qiye && next != .qiye { bookModule?.active(false) }
        if module == .yokai && next != .yokai { comicSession?.phase(.inactive); ReaderOrientation.apply("free") }
        module = next
        if next == .qiye { bookModule?.active(true) }
    }
    func open(_ url: URL) {
        if let module = HubRoute.module(for: url) { show(module); return }
        guard url.isFileURL else { return }
        if let module = HubRoute.fileModule(for: url) { importFile(url, into: module) }
        else { incomingFile = url }
    }
    func importFile(_ url: URL, into module: ReaderModule) {
        show(module)
        if module == .qiye { books.receive(url) }
        else { Task { await comics.open(url) } }
        incomingFile = nil
    }
    func pendingShortcut() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "hub.pendingModule"), let next = ReaderModule(rawValue: raw) else { return }
        defaults.removeObject(forKey: "hub.pendingModule"); show(next)
    }
    func phase(_ phase: ScenePhase) {
        scenePhase = phase
        comicSession?.phase(phase)
        if phase == .background {
            QiyeReaderModule.scheduleBackgroundRefresh()
            bookModule?.background()
        }
        if phase == .active {
            pendingShortcut()
            if module == .qiye { bookModule?.foreground() }
        }
    }
    func backgroundRefresh() async { await comics.maintain(); AppMaintenance.schedule() }
}

@main
@MainActor
final class ReadingHubAppDelegate: UIResponder, UIApplicationDelegate {
    let router = HubRouter()
    private var observers = Set<AnyCancellable>()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        QiyeReaderModule.prepareBackgroundRefresh()
        #if MIGRATE_LIVE_CONTAINER
        do { try HostKeychainMigration.perform() }
        catch { migrationError = error.localizedDescription }
        #endif
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppMaintenance.identifier, using: .main) { [weak self] task in
            let work = Task { @MainActor in
                await self?.router.backgroundRefresh()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
        NotificationCenter.default.publisher(for: .openHubModule).sink { [weak self] _ in self?.router.pendingShortcut() }.store(in: &observers)
        NotificationCenter.default.publisher(for: Notification.Name("ReadingHubHome")).sink { [weak self] _ in self?.router.show(nil) }.store(in: &observers)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { router.show(.qiye) }
        #endif
        return true
    }
    var migrationError: String?
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { YokaiApplicationDelegate.readerOrientation }
}

@MainActor
final class ReadingHubSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var router: HubRouter { (UIApplication.shared.delegate as! ReadingHubAppDelegate).router }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = HubContainer(router: router)
        self.window = window; window.makeKeyAndVisible()
        for context in options.urlContexts { router.open(context.url) }
        router.pendingShortcut()
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) { for context in contexts { router.open(context.url) } }
    func sceneDidBecomeActive(_ scene: UIScene) { router.phase(.active) }
    func sceneWillResignActive(_ scene: UIScene) { router.phase(.inactive) }
    func sceneDidEnterBackground(_ scene: UIScene) { router.phase(.background) }
}

@MainActor
private final class HubContainer: UIViewController {
    let router: HubRouter
    private var observers = Set<AnyCancellable>()
    private var current: UIViewController?
    private var comicController: UIViewController?
    private lazy var home = UIHostingController(rootView: HubHomeView(router: router))
    private let switchButton = UIButton(type: .system)
    override var childForStatusBarHidden: UIViewController? { current }
    override var childForStatusBarStyle: UIViewController? { current }
    override var childForHomeIndicatorAutoHidden: UIViewController? { current }
    init(router: HubRouter) { self.router = router; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        switchButton.setImage(UIImage(systemName: "square.grid.2x2"), for: .normal)
        switchButton.accessibilityLabel = "切换阅读器"
        switchButton.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
        switchButton.layer.cornerRadius = 18
        switchButton.addAction(UIAction { [weak self] _ in self?.router.show(nil) }, for: .touchUpInside)
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(switchButton)
        NSLayoutConstraint.activate([
            switchButton.widthAnchor.constraint(equalToConstant: 36), switchButton.heightAnchor.constraint(equalToConstant: 36),
            switchButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            switchButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4)
        ])
        router.$module.sink { [weak self] next in self?.mount(next) }.store(in: &observers)
        router.$incomingFile.compactMap { $0 }.sink { [weak self] url in self?.chooseReader(url) }.store(in: &observers)
    }
    private func mount(_ module: ReaderModule?) {
        let next: UIViewController
        switch module {
        case .yokai:
            if comicController == nil { comicController = UIHostingController(rootView: HubComicsView(router: router)) }
            next = comicController!
        case .qiye:
            next = router.books.viewController
            router.books.onReadingChanged = { [weak self] reading in self?.switchButton.isHidden = reading }
        case nil: next = home
        }
        guard current !== next else { return }
        current?.dismiss(animated: false)
        current?.willMove(toParent: nil); current?.view.removeFromSuperview(); current?.removeFromParent()
        addChild(next); view.insertSubview(next.view, at: 0); next.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),next.view.topAnchor.constraint(equalTo: view.topAnchor),next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        next.didMove(toParent: self); current = next
        switchButton.isHidden = module != .qiye || router.books.isReading
        setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    private func chooseReader(_ url: URL) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "导入到哪个书库？", message: url.lastPathComponent, preferredStyle: .actionSheet)
        for module in ReaderModule.allCases { alert.addAction(UIAlertAction(title: module.title, style: .default) { [weak self] _ in self?.router.importFile(url, into: module) }) }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.router.incomingFile = nil })
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX,y: view.bounds.midY,width: 1,height: 1)
        present(alert, animated: true)
    }
}

private struct HubComicsView: View {
    @ObservedObject var router: HubRouter
    var body: some View {
        YokaiRootView(session: router.comics)
            .environment(\.scenePhase, router.scenePhase)
    }
}

private struct HubHomeView: View {
    @ObservedObject var router: HubRouter
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ReaderModule.allCases) { module in
                        Button { router.show(module) } label: { Label(module.title, systemImage: module.symbol).font(.title3).padding(.vertical, 16) }
                    }
                }
                Section("分别启动") {
                    Text("在快捷指令中添加“打开阅读器”，选择漫画或栖页。也可以使用“打开 URL”：")
                    Text("readinghub://yokai\nreadinghub://qiye").font(.footnote.monospaced()).textSelection(.enabled)
                }
            }.navigationTitle("书房")
        }
    }
}

extension Notification.Name { static let openHubModule = Notification.Name("ReadingHubOpenModule") }
