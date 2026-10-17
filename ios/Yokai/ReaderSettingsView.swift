import SwiftUI

struct ReaderModeChoices: View {
    var body: some View {
        Text("从左向右").tag("ltr")
        Text("从右向左").tag("rtl")
        Text("从上到下（翻页）").tag("verticalPager")
        Text("条漫").tag("webtoon")
        Text("从上到下（连续）").tag("vertical")
    }
}

struct ReaderScaleChoices: View {
    var body: some View {
        Text("适应屏幕").tag("fit"); Text("填满屏幕").tag("fill")
        Text("适应宽度").tag("width"); Text("适应高度").tag("height")
        Text("原始大小").tag("original"); Text("智能适应").tag("smart"); Text("拉伸").tag("stretch")
    }
}

struct ReaderLayoutChoices: View {
    var body: some View {
        Text("单页").tag("single"); Text("双页").tag("double")
        Text("自动（随屏幕方向）").tag("automatic"); Text("拆分横向跨页").tag("split")
    }
}

struct ReaderToolbarSettingsView: View {
    @AppStorage("reader.toolbar.items", store: YokaiStorage.defaults) private var storedItems = ReaderToolbarItem.defaults
    private var items: [ReaderToolbarItem] { ReaderToolbarItem.items(from: storedItems) }
    private func save(_ items: [ReaderToolbarItem]) { storedItems = items.map(\.rawValue).joined(separator: ",") }
    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    Label(item.title, systemImage: item.symbol).id("shown." + item.rawValue)
                }
                    .onMove { source, destination in
                        var updated = items; updated.move(fromOffsets: source, toOffset: destination); save(updated)
                    }
                    .onDelete { offsets in
                        var updated = items; updated.remove(atOffsets: offsets); save(updated)
                    }
            } header: { Text("已显示") } footer: { Text("拖动右侧把手调整顺序，点减号隐藏。自动滚动仅在连续阅读时显示。") }
            Section("可添加") {
                ForEach(ReaderToolbarItem.allCases.filter { !items.contains($0) }) { item in
                    Button { save(items + [item]) } label: { Label(item.title, systemImage: "plus.circle") }
                        .accessibilityIdentifier("readerToolbarAdd.\(item.rawValue)")
                        .id("available." + item.rawValue)
                }
            }
            Button("恢复默认工具栏") { storedItems = ReaderToolbarItem.defaults }
                .accessibilityIdentifier("readerToolbarReset")
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("阅读工具栏").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("readerToolbarEditor")
    }
}

struct MangaReaderSettingsView: View {
    let bookID: String
    @EnvironmentObject private var library: ComicLibrary
    @Environment(\.dismiss) private var dismiss
    private var settings: MangaReaderSettings { library.books.first { $0.id == bookID }?.readerSettings ?? MangaReaderSettings() }
    private func string(_ path: WritableKeyPath<MangaReaderSettings, String?>) -> Binding<String> {
        Binding(get: { settings[keyPath: path] ?? "default" }, set: { value in var settings = settings; settings[keyPath: path] = value == "default" ? nil : value; library.setReaderSettings(settings, bookID: bookID) })
    }
    private func flag(_ path: WritableKeyPath<MangaReaderSettings, Bool?>) -> Binding<String> {
        Binding(get: { settings[keyPath: path].map { $0 ? "yes" : "no" } ?? "default" }, set: { value in var settings = settings; settings[keyPath: path] = value == "default" ? nil : value == "yes"; library.setReaderSettings(settings, bookID: bookID) })
    }
    var body: some View {
        Form {
            Section("本书设置") {
                Picker("阅读方式", selection: string(\.mode)) { Text("跟随默认").tag("default"); ReaderModeChoices() }
                #if !targetEnvironment(macCatalyst)
                Picker("屏幕方向", selection: string(\.orientation)) { Text("跟随默认").tag("default"); Text("自由旋转").tag("free"); Text("竖屏").tag("portrait"); Text("横屏").tag("landscape") }
                #endif
                Picker("图片缩放", selection: string(\.scale)) { Text("跟随默认").tag("default"); ReaderScaleChoices() }
                Picker("页面布局", selection: string(\.layout)) { Text("跟随默认").tag("default"); ReaderLayoutChoices() }
                option("裁剪边框", flag(\.trimBorders))
                Button("全部跟随默认") { library.setReaderSettings(MangaReaderSettings(), bookID: bookID) }
            }
            NavigationLink("默认阅读设置") { ReaderDefaultsView() }
        }.navigationTitle("本书阅读设置").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("完成") { dismiss() } }
    }
    private func option(_ name: String, _ value: Binding<String>) -> some View {
        Picker(name, selection: value) { Text("跟随默认").tag("default"); Text("开启").tag("yes"); Text("关闭").tag("no") }
    }
}

struct ReaderDefaultsView: View {
    @AppStorage("readerMode", store: YokaiStorage.defaults) private var mode = "webtoon"
    @AppStorage("reader.doublePage", store: YokaiStorage.defaults) private var doublePage = false
    @AppStorage("reader.layout", store: YokaiStorage.defaults) private var layout = "automatic"
    @AppStorage("reader.splitPortrait", store: YokaiStorage.defaults) private var splitPortrait = false
    @AppStorage("reader.invertDoublePages", store: YokaiStorage.defaults) private var invertDoublePages = false
    @AppStorage("reader.shiftDoublePage", store: YokaiStorage.defaults) private var shiftDoublePage = false
    @AppStorage("reader.webtoonSplit", store: YokaiStorage.defaults) private var webtoonSplit = false
    @AppStorage("reader.webtoonInvertDoublePages", store: YokaiStorage.defaults) private var webtoonInvert = false
    @AppStorage("reader.scale", store: YokaiStorage.defaults) private var scale = "fit"
    @AppStorage("reader.orientation", store: YokaiStorage.defaults) private var orientation = "free"
    @AppStorage("reader.zoomStart", store: YokaiStorage.defaults) private var zoomStart = "auto"
    @AppStorage("reader.animate", store: YokaiStorage.defaults) private var animate = true
    @AppStorage("trimBorders", store: YokaiStorage.defaults) private var trim = false
    @AppStorage("reader.keepAwake", store: YokaiStorage.defaults) private var awake = true
    @AppStorage("reader.fullscreen", store: YokaiStorage.defaults) private var fullscreen = true
    @AppStorage("reader.showPageNumber", store: YokaiStorage.defaults) private var numbers = true
    @AppStorage("reader.skipRead", store: YokaiStorage.defaults) private var skipRead = false
    @AppStorage("reader.skipFiltered", store: YokaiStorage.defaults) private var skipFiltered = false
    @AppStorage("reader.skipDuplicate", store: YokaiStorage.defaults) private var skipDuplicate = true
    @AppStorage("reader.grayscale", store: YokaiStorage.defaults) private var grayscale = false
    @AppStorage("reader.inverted", store: YokaiStorage.defaults) private var inverted = false
    @AppStorage("reader.sidePadding", store: YokaiStorage.defaults) private var padding = 0
    @AppStorage("reader.customBrightness", store: YokaiStorage.defaults) private var customBrightness = false
    @AppStorage("reader.brightness", store: YokaiStorage.defaults) private var brightness = 0.5
    @AppStorage("reader.longTap", store: YokaiStorage.defaults) private var longTap = true
    @AppStorage("reader.webtoonDoubleTap", store: YokaiStorage.defaults) private var doubleTap = true
    @AppStorage("reader.webtoonZoomOut", store: YokaiStorage.defaults) private var zoomOut = false
    @AppStorage("readerBackground", store: YokaiStorage.defaults) private var background = "black"
    @AppStorage("autoScrollSpeed", store: YokaiStorage.defaults) private var speed = 40.0
    @AppStorage("reader.holdToScroll", store: YokaiStorage.defaults) private var holdToScroll = true
    @AppStorage("downloads.aheadChapters", store: YokaiStorage.defaults) private var ahead = 0
    var body: some View {
        Form {
            Section("阅读") {
                Picker("默认阅读方式", selection: $mode) { ReaderModeChoices() }
                #if !targetEnvironment(macCatalyst)
                Picker("屏幕方向", selection: $orientation) { Text("自由旋转").tag("free"); Text("竖屏").tag("portrait"); Text("横屏").tag("landscape") }
                #endif
                Picker("图片缩放", selection: $scale) { ReaderScaleChoices() }
                Picker("放大起始位置", selection: $zoomStart) { Text("跟随阅读方向").tag("auto"); Text("左侧").tag("left"); Text("右侧").tag("right"); Text("中间").tag("center") }
                Toggle("翻页动画", isOn: $animate)
                Picker("页面布局", selection: $layout) { ReaderLayoutChoices() }
                if layout == "automatic" { Toggle("竖屏时拆分横向跨页", isOn: $splitPortrait) }
                Toggle("交换跨页顺序", isOn: $invertDoublePages)
                Toggle("封面单独显示", isOn: $shiftDoublePage)
                Toggle("裁剪边框", isOn: $trim)
                NavigationLink("点按区域") { TapZoneSettingsView() }
                NavigationLink("阅读工具栏") { ReaderToolbarSettingsView() }
                    .accessibilityIdentifier("readerToolbarSettings")
                Toggle("长按图片显示操作", isOn: $longTap)
            }
            Section("显示") {
                Toggle("阅读时保持屏幕常亮", isOn: $awake)
                #if !targetEnvironment(macCatalyst)
                Toggle("全屏", isOn: $fullscreen)
                #endif
                Toggle("显示页码", isOn: $numbers)
                Picker("背景", selection: $background) { Text("黑色").tag("black"); Text("灰色").tag("gray"); Text("纸色").tag("paper"); Text("白色").tag("white") }
                #if !targetEnvironment(macCatalyst)
                Toggle("自定义亮度", isOn: $customBrightness)
                if customBrightness {
                    LabeledContent("亮度", value: brightness == 0 ? "系统亮度" : "\(Int(brightness * 100))%")
                    Slider(value: $brightness, in: -0.75...1, step: 0.01).accessibilityLabel("屏幕亮度")
                }
                #endif
                Toggle("灰度", isOn: $grayscale); Toggle("反转颜色", isOn: $inverted)
                NavigationLink("颜色滤镜") { ReaderColorSettingsView() }
            }
            Section("连续阅读") {
                Picker("侧边留白", selection: $padding) { ForEach([0, 5, 10, 15, 20, 25], id: \.self) { Text("\($0)%").tag($0) } }
                LabeledContent("自动滚动速度", value: "\(Int(speed))")
                Slider(value: $speed, in: 10...150)
                Toggle("边缘长按滚动", isOn: $holdToScroll)
                    .accessibilityIdentifier("readerHoldToScroll")
                if holdToScroll {
                    Text("隐藏工具栏后，按住屏幕左右边缘滚动；上滑加速，下滑减速，松手停止。图片中间仍可长按显示操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("双击缩放", isOn: $doubleTap)
                Toggle("允许缩小图片", isOn: $zoomOut)
                Toggle("拆分并上下排列横向跨页", isOn: $webtoonSplit)
                if webtoonSplit { Toggle("右半页在上", isOn: $webtoonInvert) }
            }
            Section("章节切换") {
                Toggle("跳过已读章节", isOn: $skipRead); Toggle("跳过筛选隐藏的章节", isOn: $skipFiltered); Toggle("跳过相同编号的重复章节", isOn: $skipDuplicate)
                Stepper("提前下载 \(ahead) 章", value: $ahead, in: 0...10)
            }
        }.navigationTitle("阅读").navigationBarTitleDisplayMode(.inline)
            .onChange(of: layout) { _, _ in doublePage = false }
    }
}

/// Uses UIKit's vertical and horizontal page navigation rather than treating a
/// vertical pager as a continuously scrolling webtoon.
struct NativePageReader: UIViewControllerRepresentable {
    @Binding var page: Int?
    let pages: [Int]
    let vertical: Bool
    let reversed: Bool
    var animate = true
    let onBoundary: (Int) -> Void
    let content: (Int) -> AnyView
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: vertical ? .vertical : .horizontal)
        controller.dataSource = context.coordinator; controller.delegate = context.coordinator
        let gesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.boundary(_:)))
        gesture.delegate = context.coordinator; controller.view.addGestureRecognizer(gesture)
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        let index = pages.last(where: { $0 <= (page ?? 0) }) ?? 0
        guard !coordinator.transitioning else { return }
        if let current = controller.viewControllers?.first as? Page, current.index == index { current.rootView = content(index) }
        else {
            let previous = (controller.viewControllers?.first as? Page)?.index ?? index
            let forward = reversed ? index < previous : index > previous
            let animated = animate && previous != index && controller.viewControllers?.isEmpty == false
            coordinator.transitioning = animated
            controller.setViewControllers([coordinator.view(index)], direction: forward ? .forward : .reverse, animated: animated) { _ in coordinator.transitioning = false }
        }
    }
    final class Page: UIHostingController<AnyView> {
        let index: Int
        init(index: Int, content: AnyView) { self.index = index; super.init(rootView: content); view.backgroundColor = .clear }
        @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is unsupported") }
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: NativePageReader
        var transitioning = false
        var startingPage = 0
        weak var imageScroll: UIScrollView?
        var initialOffset = CGPoint.zero
        init(_ parent: NativePageReader) { self.parent = parent }
        func view(_ index: Int) -> Page { Page(index: index, content: parent.content(index)) }
        func neighbor(_ controller: UIViewController, _ direction: Int) -> UIViewController? {
            guard let current = controller as? Page, let i = parent.pages.firstIndex(of: current.index) else { return nil }
            let target = i + (parent.reversed ? -direction : direction)
            return parent.pages.indices.contains(target) ? view(parent.pages[target]) : nil
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? { neighbor(viewController, -1) }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? { neighbor(viewController, 1) }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { transitioning = true }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            if completed, let current = pageViewController.viewControllers?.first as? Page { parent.page = current.index }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func boundary(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                startingPage = parent.pages.last(where: { $0 <= (parent.page ?? 0) }) ?? 0
                var touched = gesture.view?.hitTest(gesture.location(in: gesture.view), with: nil)
                imageScroll = nil
                while let view = touched {
                    if let scroll = view as? UIScrollView, scroll.maximumZoomScale > 1 { imageScroll = scroll; initialOffset = scroll.contentOffset; break }
                    touched = view.superview
                }
            }
            guard gesture.state == .ended else { return }
            let delta = gesture.translation(in: gesture.view), movement = parent.vertical ? delta.y : delta.x
            guard abs(movement) > 80 else { return }
            let next = (parent.reversed && !parent.vertical) ? movement > 0 : movement < 0
            if let scroll = imageScroll {
                if scroll.zoomScale > 1.01 { return }
                let offset = parent.vertical ? initialOffset.y : initialOffset.x
                let end = max(0, parent.vertical ? scroll.contentSize.height - scroll.bounds.height : scroll.contentSize.width - scroll.bounds.width)
                if end > 1 {
                    let towardEnd = movement < 0
                    if towardEnd && offset < end - 1 { return }
                    if !towardEnd && offset > 1 { return }
                }
            }
            if next && startingPage == parent.pages.last { parent.onBoundary(1) }
            if !next && startingPage == parent.pages.first { parent.onBoundary(-1) }
        }
    }
}
