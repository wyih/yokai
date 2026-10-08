import SwiftUI
import PDFKit

struct ReaderView: View {
    private let initialBook: ComicBook
    private let initialDirectory: URL
    @State private var activeBook: ComicBook?
    @EnvironmentObject private var extensions: ExtensionStore
    private var book: ComicBook { activeBook ?? initialBook }
    private var directory: URL { activeBook == nil ? initialDirectory : library.directory(for: book) }
    init(book: ComicBook, directory: URL) { initialBook = book; initialDirectory = directory }
    @EnvironmentObject private var library: ComicLibrary
    @EnvironmentObject private var downloads: DownloadStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("readerMode", store: YokaiStorage.defaults) private var defaultMode = "webtoon"
    @AppStorage("rightToLeft", store: YokaiStorage.defaults) private var rightToLeft = true
    @AppStorage("readerBackground", store: YokaiStorage.defaults) private var background = "black"
    @AppStorage("trimBorders", store: YokaiStorage.defaults) private var trimBorders = false
    @AppStorage("autoScrollSpeed", store: YokaiStorage.defaults) private var autoScrollSpeed = 40.0
    @AppStorage("reader.doublePage", store: YokaiStorage.defaults) private var defaultDoublePage = false
    @AppStorage("reader.layout", store: YokaiStorage.defaults) private var defaultLayout = "automatic"
    @AppStorage("reader.splitPortrait", store: YokaiStorage.defaults) private var splitPortrait = false
    @AppStorage("reader.invertDoublePages", store: YokaiStorage.defaults) private var invertDoublePages = false
    @AppStorage("reader.shiftDoublePage", store: YokaiStorage.defaults) private var shiftDoublePage = false
    @AppStorage("reader.webtoonSplit", store: YokaiStorage.defaults) private var webtoonSplit = false
    @AppStorage("reader.webtoonInvertDoublePages", store: YokaiStorage.defaults) private var webtoonRightFirst = false
    @AppStorage("reader.scale", store: YokaiStorage.defaults) private var defaultScale = "fit"
    @AppStorage("reader.orientation", store: YokaiStorage.defaults) private var defaultOrientation = "free"
    @AppStorage("reader.animate", store: YokaiStorage.defaults) private var animate = true
    @AppStorage("reader.zoomStart", store: YokaiStorage.defaults) private var zoomStart = "auto"
    @AppStorage("reader.skipRead", store: YokaiStorage.defaults) private var skipRead = false
    @AppStorage("reader.skipFiltered", store: YokaiStorage.defaults) private var skipFiltered = false
    @AppStorage("reader.skipDuplicate", store: YokaiStorage.defaults) private var skipDuplicate = true
    @AppStorage("reader.keepAwake", store: YokaiStorage.defaults) private var keepAwake = true
    @AppStorage("reader.fullscreen", store: YokaiStorage.defaults) private var fullscreen = true
    @AppStorage("reader.showPageNumber", store: YokaiStorage.defaults) private var showPageNumber = true
    @AppStorage("reader.grayscale", store: YokaiStorage.defaults) private var grayscale = false
    @AppStorage("reader.inverted", store: YokaiStorage.defaults) private var inverted = false
    @AppStorage("reader.sidePadding", store: YokaiStorage.defaults) private var sidePadding = 0
    @AppStorage("reader.customBrightness", store: YokaiStorage.defaults) private var customBrightness = false
    @AppStorage("reader.brightness", store: YokaiStorage.defaults) private var brightness = 0.5
    @AppStorage("reader.webtoonDoubleTap", store: YokaiStorage.defaults) private var webtoonDoubleTap = true
    @AppStorage("reader.webtoonZoomOut", store: YokaiStorage.defaults) private var webtoonZoomOut = false
    @AppStorage("downloads.aheadChapters", store: YokaiStorage.defaults) private var aheadChapters = 0
    @State private var brightnessControl = ReaderBrightness()
    @State private var readerVisible = false
    @State private var oldIdleTimer = false
    @State private var requestedChapter: String?
    @State private var chapterError: String?
    @State private var configuringReader = false
    @State private var prefetchedChapter: String?
    private var readerSettings: MangaReaderSettings { library.books.first { $0.id == book.id }?.readerSettings ?? MangaReaderSettings() }
    private var mode: String {
        let value = readerSettings.mode ?? defaultMode
        return value == "horizontal" ? (rightToLeft ? "rtl" : "ltr") : value
    }
    private var continuous: Bool { mode == "vertical" || mode == "webtoon" }
    private var layout: String { readerSettings.layout ?? (mode == "double" || (readerSettings.doublePage ?? defaultDoublePage) ? "double" : defaultLayout) }
    private var doublePage: Bool { layout == "double" || (layout == "automatic" && viewport.width > viewport.height) }
    private var splitPage: Bool { layout == "split" || (layout == "automatic" && !doublePage && splitPortrait) }
    private var readingFrames: [ReadingFrame] {
        ReadingLayout.frames(count: book.pageCount, wide: Set(imageWidths.filter(\.value).map(\.key)),
            double: doublePage, split: splitPage, rightFirst: (mode == "rtl") != invertDoublePages, shift: shiftDoublePage)
    }
    private var scanID: String { directory.path + "-" + String(currentDownload?.completed ?? 0) + "-" + String(book.pageCount) + "-" + String(continuous) + "-" + String(document?.pageCount ?? 0) }
    private var effectiveTrim: Bool { readerSettings.trimBorders ?? trimBorders }
    private var scale: String { readerSettings.scale ?? defaultScale }
    private var orientation: String { readerSettings.orientation ?? defaultOrientation }
    private var effectiveZoomStart: String { zoomStart == "auto" ? (mode == "rtl" ? "right" : mode == "ltr" ? "left" : "center") : zoomStart }
    private var modeBinding: Binding<String> { Binding(get: { readerSettings.mode ?? "default" }, set: { value in var settings = readerSettings; settings.mode = value == "default" ? nil : value; library.setReaderSettings(settings, bookID: book.id) }) }
    @State private var autoScroll = false
    @State private var page: Int?
    @State private var scrollTarget: Int?
    @State private var scrollJump = 0
    @State private var restoringPosition = true
    @State private var document: PDFDocument?
    @State private var controls = true
    @State private var scrollRequest = 0
    @State private var continuousZoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var shareImage: ImageShareItem?
    @State private var imageMessage: String?
    @State private var viewport = CGSize.zero
    @State private var pageImageSizes: [Int: CGSize] = [:]
    @State private var sizeScanDirectory = ""
    private var imageWidths: [Int: Bool] {
        sizeScanDirectory == directory.path ? pageImageSizes.mapValues { $0.width > $0.height } : [:]
    }
    @State private var displayFrame: Int?

    private var bookmarks: [ComicBookmark] {
        library.books.first(where: { $0.id == book.id })?.bookmarks.filter { !$0.deleted && $0.chapterURL == book.origin?.chapterURL } ?? []
    }
    private var currentDownload: ChapterDownload? {
        downloads.jobs.first { $0.sourceID == book.origin?.sourceID && $0.manga.url == book.origin?.mangaURL && $0.chapter.url == book.origin?.chapterURL }
    }

    var body: some View {
        GeometryReader { geometry in
        ZStack {
            ReaderAppearance.color(background).ignoresSafeArea()
            if continuous {
                if sizeScanDirectory == directory.path {
                    ScrollViewReader { proxy in
                        ScrollView(continuousZoom > 1 ? [.vertical, .horizontal] : .vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(0..<book.pageCount, id: \.self) { index in
                                    ComicPage(directory: directory, format: book.format, document: document, index: index, fit: false, trimBorders: effectiveTrim, scale: scale,
                                              cacheVersion: currentDownload?.completed ?? 0,
                                              placeholderAspect: continuousAspect(index),
                                              stackSpread: webtoonSplit, rightFirst: webtoonRightFirst, spreadGap: mode == "vertical" ? 15 : 0,
                                              onDoubleTap: { if webtoonDoubleTap { continuousZoom = continuousZoom > 1 ? 1 : 2.5 } },
                                              onAction: imageAction, onTap: { tap($0, size: geometry.size) })
                                        // Android WebtoonPageHolder uses WRAP_CONTENT and a
                                        // 15dp bottom margin only for continuous vertical mode.
                                        .padding(.bottom, mode == "vertical" ? 15 : 0)
                                        .id(index)
                                        .background(GeometryReader { proxy in
                                            Color.clear.preference(key: ReaderPageFrames.self,
                                                                   value: [index: proxy.frame(in: .named("readerScroll"))])
                                        })
                                }
                            }
                            .padding(.horizontal, geometry.size.width * CGFloat(sidePadding) / 100)
                            .frame(width: geometry.size.width * continuousZoom)
                            .background(AutoScrollDriver(enabled: autoScroll, speed: autoScrollSpeed, scrollRequest: scrollRequest, onBoundary: { openAdjacent($0) }))
                            .frame(minWidth: geometry.size.width)
                        }
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        .modifier(ReaderImageFilter(grayscale: grayscale, inverted: inverted))
                        .modifier(ReaderColorFilter())
                        .simultaneousGesture(MagnificationGesture().onChanged { value in
                            if pinchStart == nil { pinchStart = continuousZoom }
                            continuousZoom = max(webtoonZoomOut ? 0.5 : 1, min(5, (pinchStart ?? 1) * value))
                        }.onEnded { _ in pinchStart = nil })
                        .id(book.origin?.chapterURL ?? book.id)
                        .coordinateSpace(name: "readerScroll")
                        // A persistent scrollPosition anchor overrides UIKit's screen-distance
                        // scrolling on the next update. Only explicit jumps should reposition it.
                        .onChange(of: scrollJump) { _, _ in
                            if let scrollTarget { proxy.scrollTo(scrollTarget, anchor: .top) }
                        }
                        .onAppear { proxy.scrollTo(page ?? book.lastPage, anchor: .top) }
                        .onDisappear { restoringPosition = true }
                        .onPreferenceChange(ReaderPageFrames.self) { frames in
                            if restoringPosition {
                                let target = page ?? book.lastPage
                                guard let frame = frames[target], frame.maxY > 0,
                                      frame.minY <= 1 || (target == book.pageCount - 1 && frame.maxY <= geometry.size.height + 1) else { return }
                                restoringPosition = false
                            }
                            // Match Android WebtoonLayoutManager.findLastEndVisibleItemPosition:
                            // keep the current page until another image's bottom is visible.
                            // LazyVStack also reports retained offscreen children; RecyclerView's
                            // jump layout omits those. Only consider image ends in the viewport.
                            if let visible = frames.filter({ $0.value.maxY > 1 && $0.value.maxY <= geometry.size.height + 1 }).keys.max() {
                                #if DEBUG && targetEnvironment(simulator)
                                if ProcessInfo.processInfo.arguments.contains("-YokaiReaderTrace"), page != visible {
                                    FileHandle.standardError.write(Data("Reader visible \(visible) anchor \(scrollTarget ?? -1) frame \(frames[visible]!)\n".utf8))
                                }
                                #endif
                                page = visible
                            }
                        }
                    }
                } else { ProgressView().tint(.gray) }
            } else {
                NativePageReader(page: $displayFrame, pages: readingFrames.map(\.id),
                                 vertical: mode == "verticalPager", reversed: mode == "rtl", animate: animate, onBoundary: { direction in openAdjacent(direction) }) { index in
                    AnyView(HStack(spacing: 2) {
                        if let frame = readingFrames.first(where: { $0.id == index }) {
                            ForEach(Array(frame.segments.enumerated()), id: \.offset) { _, segment in
                            ComicPage(directory: directory, format: book.format, document: document, index: segment.page, fit: true,
                                      trimBorders: effectiveTrim, scale: scale, zoomStart: effectiveZoomStart, cacheVersion: currentDownload?.completed ?? 0,
                                      half: segment.half,
                                      onAction: imageAction,
                                      onTap: { tap(CGPoint(x: $0.x - geometry.frame(in: .global).minX, y: $0.y - geometry.frame(in: .global).minY), size: geometry.size) })
                            }
                        }
                    }.environment(\.layoutDirection, (mode == "rtl") != invertDoublePages ? .rightToLeft : .leftToRight)
                     .modifier(ReaderImageFilter(grayscale: grayscale, inverted: inverted)).modifier(ReaderColorFilter()))
                }.id(mode + "-" + String(doublePage) + "-" + (book.origin?.chapterURL ?? book.id))
            }
            if let requestedChapter {
                VStack { ProgressView("正在加载下一章节…"); Button("取消跳转") { self.requestedChapter = nil } }
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).id(requestedChapter)
            }
            if customBrightness && brightness < 0 { Color.black.opacity(-brightness).ignoresSafeArea().allowsHitTesting(false) }
            if !controls && showPageNumber {
                VStack { Spacer(); Text("\((page ?? 0) + 1) / \(book.pageCount)").font(.caption).monospacedDigit().padding(6).background(.regularMaterial, in: Capsule()) }
                    .allowsHitTesting(false).padding(.bottom, 8)
            }
            if controls {
                VStack(spacing: 0) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("关闭阅读器")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title).font(.headline).lineLimit(1)
                            if let chapter = book.origin?.chapterTitle { Text(chapter).font(.caption).lineLimit(1) }
                        }
                        Spacer()
                        Button {
                            library.toggleBookmark(page ?? 0, for: book.id)
                        } label: {
                            Image(systemName: bookmarks.contains(where: { $0.page == (page ?? 0) }) ? "bookmark.fill" : "bookmark")
                        }.accessibilityLabel("切换当前页书签")
                        Menu {
                            Picker("本书阅读方式", selection: modeBinding) { Text("跟随默认").tag("default"); ReaderModeChoices() }
                            Picker("本书页面布局", selection: Binding(get: { readerSettings.layout ?? "default" }, set: { value in var settings = readerSettings; settings.layout = value == "default" ? nil : value; settings.doublePage = nil; library.setReaderSettings(settings, bookID: book.id) })) { Text("跟随默认").tag("default"); ReaderLayoutChoices() }
                            if doublePage { Toggle("封面单独显示", isOn: $shiftDoublePage) }
                            Toggle("裁剪边框", isOn: Binding(get: { effectiveTrim }, set: { var settings = readerSettings; settings.trimBorders = $0; library.setReaderSettings(settings, bookID: book.id) }))
                            Button("本书阅读设置") { configuringReader = true }
                            Picker("背景", selection: $background) {
                                Text("黑色").tag("black"); Text("灰色").tag("gray"); Text("纸色").tag("paper"); Text("白色").tag("white")
                            }
                            if continuous { Toggle("自动滚动", isOn: $autoScroll) }
                            Button("点按区域设置") { configuringTapZones = true }
                            if !bookmarks.isEmpty {
                                Section("书签") {
                                    ForEach(bookmarks.sorted { $0.page < $1.page }) { mark in
                                        Button(mark.title) { jump(to: mark.page) }
                                    }
                                }
                            }
                        } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("阅读设置")
                    }
                    .padding().background(.ultraThinMaterial)
                    Spacer()
                    if let job = currentDownload, job.state == .failed || job.state == .paused {
                        HStack {
                            Text(job.error ?? "章节加载已暂停").font(.caption).lineLimit(2)
                            Button("继续加载") { downloads.resume(job.id) }
                        }.padding().background(.ultraThinMaterial)
                    }
                    HStack {
                        if book.origin != nil { Button("上一章", systemImage: "backward.end") { openAdjacent(-1) }.labelStyle(.iconOnly).disabled(adjacent(-1) == nil) }
                        Text("\((page ?? 0) + 1) / \(book.pageCount)").monospacedDigit().font(.caption)
                            .accessibilityIdentifier("readerPage")
                        if autoScroll {
                            Slider(value: $autoScrollSpeed, in: 10...150).accessibilityLabel("自动滚动速度")
                        } else if book.pageCount > 1 {
                            Slider(value: Binding(get: { Double(page ?? 0) }, set: { jump(to: Int($0)) }),
                                   in: 0...Double(book.pageCount - 1), step: 1)
                                .accessibilityLabel("跳转页码")
                        }
                        if book.origin != nil { Button("下一章", systemImage: "forward.end") { openAdjacent(1) }.labelStyle(.iconOnly).disabled(adjacent(1) == nil) }
                    }
                    .padding().background(.ultraThinMaterial)
                }
                .foregroundStyle(background == "white" || background == "paper" ? Color.black : Color.white)
            }
        }.coordinateSpace(name: "reader")
        .onAppear { viewport = geometry.size }
        .onChange(of: geometry.size) { _, size in viewport = size }
        }
        .sheet(isPresented: $configuringTapZones) { NavigationStack { TapZoneSettingsView() } }
        .sheet(item: $shareImage) { ImageShareSheet(image: $0.image) }
        .preferredColorScheme(background == "white" || background == "paper" ? .light : .dark)
        .statusBarHidden(fullscreen && !controls)
        .sheet(isPresented: $configuringReader) { NavigationStack { MangaReaderSettingsView(bookID: book.id) } }
        .alert("章节加载失败", isPresented: Binding(get: { chapterError != nil }, set: { if !$0 { chapterError = nil } })) { Button("好", role: .cancel) {} } message: { Text(chapterError ?? "") }
        .alert("图片操作", isPresented: Binding(get: { imageMessage != nil }, set: { if !$0 { imageMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(imageMessage ?? "") }
        .onAppear { readerVisible = true; oldIdleTimer = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = keepAwake; applyBrightness(); ReaderOrientation.apply(orientation) }
        .onDisappear {
            readerVisible = false
            Task { do { try await library.flushPendingSaves() } catch { library.errorMessage = error.localizedDescription } }
            downloads.leftChapter(bookID: book.id, chapterURL: book.origin?.chapterURL, order: orderedChapters.map(\.url))
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
            brightnessControl.restore()
            ReaderOrientation.apply("free")
        }
        .onChange(of: orientation) { _, value in ReaderOrientation.apply(value) }
        .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value }
        .onChange(of: brightness) { _, _ in applyBrightness() }
        .onChange(of: customBrightness) { _, _ in applyBrightness() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { brightnessControl.restore() }
            else if phase == .active { applyBrightness() }
        }
        .onReceive(downloads.$jobs) { jobs in
            guard let id = requestedChapter, let job = jobs.first(where: { $0.id == id }) else { return }
            if job.total > 0 && job.completed > 0 { requestedChapter = nil; switchChapter(job.chapter, count: job.total) }
            else if job.state == .failed { requestedChapter = nil; chapterError = job.error }
        }
        .task(id: book.origin?.chapterURL ?? book.id) {
            restoringPosition = true; autoScroll = false; prefetchedChapter = nil; continuousZoom = 1
            if book.format == .pdf { document = PDFDocument(url: directory.appendingPathComponent("comic.pdf")) }
            jump(to: book.lastPage)
        }
        .task(id: scanID) { await scanImageSizes() }
        .onChange(of: readingFrames) { old, new in
            let previous = old.first { $0.id == displayFrame }?.segments.first
            displayFrame = new.first { frame in frame.segments.contains { $0.page == (previous?.page ?? page ?? book.lastPage) && $0.half == previous?.half } }?.id
                ?? new.first { frame in frame.segments.contains { $0.page == (page ?? book.lastPage) } }?.id
            recordVisibleFrame()
        }
        .onChange(of: displayFrame) { _, _ in recordVisibleFrame() }
        .onChange(of: imageWidths) { _, _ in recordVisibleFrame() }
        .onChange(of: mode) { _, newMode in
            if newMode == "vertical" || newMode == "webtoon" { restoringPosition = true; scrollTarget = page; scrollJump += 1 }
        }
        .onChange(of: page) { _, newPage in
            if let newPage {
                if continuous { library.setPage(newPage, for: book.id) }
                if aheadChapters > 0 && newPage >= book.pageCount - 6 { preloadChapters() }
            }
        }
    }

    private func applyBrightness() {
        guard readerVisible, scenePhase == .active else { return }
        brightnessControl.apply(enabled: customBrightness, value: brightness)
    }
    private func imageAction(_ action: String, image: UIImage) {
        switch action {
        case "share": shareImage = ImageShareItem(image: image)
        case "cover": library.changeCover(book.id, image: image); imageMessage = library.errorMessage ?? "已设为封面。"
        case "save": Task { do { try await ReaderImageActions.saveToPhotos(image); imageMessage = "已保存到照片。" } catch { imageMessage = error.localizedDescription } }
        default: break
        }
    }

    @State private var configuringTapZones = false
    @AppStorage("tapZones.layout", store: YokaiStorage.defaults) private var tapLayout = "columns"
    @AppStorage("tapZones.actions", store: YokaiStorage.defaults) private var tapActions = TapZones.defaults
    @AppStorage("tapZones.followDirection", store: YokaiStorage.defaults) private var tapFollowDirection = true
    @AppStorage("tapZones.pager.preset", store: YokaiStorage.defaults) private var pagerPreset = "default"
    @AppStorage("tapZones.webtoon.preset", store: YokaiStorage.defaults) private var webtoonPreset = "default"
    @AppStorage("tapZones.pager.invert", store: YokaiStorage.defaults) private var pagerInvert = "none"
    @AppStorage("tapZones.webtoon.invert", store: YokaiStorage.defaults) private var webtoonInvert = "none"

    private func jump(to target: Int) {
        restoringPosition = true
        page = target
        scrollTarget = target
        scrollJump += 1
        displayFrame = readingFrames.first { frame in frame.segments.contains { $0.page == target } }?.id
    }

    private func recordVisibleFrame() {
        guard !continuous, let frame = readingFrames.first(where: { $0.id == displayFrame }),
              let first = frame.segments.first, let last = frame.segments.last else { return }
        page = first.page
        let finished = frame.id == readingFrames.last?.id && last.page == book.pageCount - 1 && (!splitPage || imageWidths[last.page] != nil)
        library.setPage(last.page, for: book.id, finished: finished)
    }
    private func continuousAspect(_ index: Int) -> CGFloat? {
        guard let size = pageImageSizes[index], size.height > 0 else { return nil }
        if webtoonSplit && size.width > size.height {
            return (size.width / 2) / (size.height * 2 + (mode == "vertical" ? 15 : 0))
        }
        return size.width / size.height
    }
    private func scanImageSizes() async {
        let identity = scanID, folder = directory, count = book.pageCount
        let known = sizeScanDirectory == folder.path ? pageImageSizes : [:]
        let sizes: [Int: CGSize]
        if book.format == .pdf {
            guard let document else { return }
            sizes = Dictionary(uniqueKeysWithValues: (0..<count).compactMap { index in
                guard let bounds = document.page(at: index)?.bounds(for: .mediaBox) else { return nil }
                return (index, bounds.size)
            })
        } else {
            sizes = await Task.detached {
                var result = known
                for index in 0..<count where result[index] == nil {
                    if let size = ChapterArchive.imageSize(directory: folder, index: index) { result[index] = size }
                }
                return result
            }.value
        }
        if identity == scanID && !Task.isCancelled { pageImageSizes = sizes; sizeScanDirectory = folder.path }
    }

    private func tap(_ location: CGPoint, size: CGSize) {
        let continuous = self.continuous
        let preset = continuous ? webtoonPreset : pagerPreset
        let action = TapZones.action(at: location, size: size, preset: preset, continuous: continuous,
                                     invert: continuous ? webtoonInvert : pagerInvert, layout: tapLayout, actions: tapActions,
                                     reversed: !continuous && mode == "rtl" && (preset != "custom" || tapFollowDirection))
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-YokaiReaderTrace") {
            FileHandle.standardError.write(Data("Reader tap \(location) \(size) action \(action) page \(page ?? -1) anchor \(scrollTarget ?? -1) request \(scrollRequest)\n".utf8))
        }
        #endif
        switch action {
        case "previous": if continuous { scrollRequest -= 1 } else if (displayFrame ?? 0) == 0 { openAdjacent(-1) } else { displayFrame = max(0, (displayFrame ?? 0) - 1) }
        case "next": if continuous { scrollRequest += 1 } else if (displayFrame ?? 0) + 1 >= readingFrames.count { openAdjacent(1) } else { displayFrame = min(readingFrames.count - 1, (displayFrame ?? 0) + 1) }
        case "controls": controls.toggle()
        default: break
        }
    }
    private var orderedChapters: [SourceChapter] {
        let chapters = library.cachedDetails(for: book)?.chapters ?? []
        var options = ChapterDisplayOptions()
        if let data = YokaiStorage.defaults.data(forKey: "chapters.display." + book.id), let saved = try? JSONDecoder().decode(ChapterDisplayOptions.self, from: data) { options = saved }
        if options.sort == "source" { return Array(chapters.reversed()) }
        return chapters.sorted { a, b in options.sort == "uploaded" ? a.uploaded < b.uploaded : a.number < b.number }
    }
    private func adjacent(_ direction: Int) -> SourceChapter? {
        guard let current = orderedChapters.firstIndex(where: { $0.url == book.origin?.chapterURL }) else { return nil }
        var index = current + direction
        let original = orderedChapters[current]
        var filters = ChapterDisplayOptions()
        if let data = YokaiStorage.defaults.data(forKey: "chapters.display." + book.id), let saved = try? JSONDecoder().decode(ChapterDisplayOptions.self, from: data) { filters = saved }
        let progress = library.books.first { $0.id == book.id }?.chapters ?? []
        while orderedChapters.indices.contains(index) {
            let chapter = orderedChapters[index], state = progress.first { $0.url == chapter.url }
            let duplicate = skipDuplicate && original.number >= 0 && chapter.number == original.number
            let downloaded = FileManager.default.fileExists(atPath: library.chapterDirectory(bookID: book.id, chapterURL: chapter.url).appendingPathComponent("chapter.json").path)
            func accepts(_ filter: String, _ value: Bool) -> Bool { filter == "all" || (filter == "yes" ? value : !value) }
            let filtered = skipFiltered && (!accepts(filters.read, state?.completed == true) || !accepts(filters.bookmarked, state?.bookmarked == true) || !accepts(filters.downloaded, downloaded))
            if !duplicate && !filtered && !(skipRead && state?.completed == true) { return chapter }
            index += direction
        }
        return nil
    }
    private func openAdjacent(_ direction: Int) {
        guard requestedChapter == nil, let chapter = adjacent(direction) else { return }
        let folder = library.chapterDirectory(bookID: book.id, chapterURL: chapter.url)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("chapter.json")), let cached = try? JSONDecoder().decode(CachedChapter.self, from: data) { switchChapter(chapter, count: cached.pageCount); return }
        guard let origin = book.origin, let source = extensions.sources.first(where: { $0.id == origin.sourceID }) else { chapterError = "请安装此漫画的图源插件。"; return }
        let manga = library.cachedDetails(for: book)?.manga ?? SourceManga(url: origin.mangaURL, title: book.title, thumbnail: origin.thumbnail, memo: origin.mangaMemo)
        let id = downloads.enqueue(source: source, manga: manga, chapter: chapter, forReading: true)
        requestedChapter = id
        if let job = downloads.jobs.first(where: { $0.id == id }), job.total > 0 && job.completed > 0 { requestedChapter = nil; switchChapter(chapter, count: job.total) }
    }
    private func switchChapter(_ chapter: SourceChapter, count: Int) {
        downloads.leftChapter(bookID: book.id, chapterURL: book.origin?.chapterURL, order: orderedChapters.map(\.url))
        guard let updated = library.openChapter(chapter, pages: count, bookID: book.id) else { return }
        document = nil; activeBook = updated; page = updated.lastPage; scrollTarget = updated.lastPage
    }
    private func preloadChapters() {
        guard prefetchedChapter != book.origin?.chapterURL, let current = orderedChapters.firstIndex(where: { $0.url == book.origin?.chapterURL }),
              let origin = book.origin, let source = extensions.sources.first(where: { $0.id == origin.sourceID }), let details = library.cachedDetails(for: book) else { return }
        prefetchedChapter = origin.chapterURL
        for chapter in orderedChapters.dropFirst(current + 1).prefix(aheadChapters) {
            let folder = library.chapterDirectory(bookID: book.id, chapterURL: chapter.url)
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("chapter.json").path) { downloads.enqueue(source: source, manga: details.manga, chapter: chapter, userInitiated: false) }
        }
    }

}

private struct ReaderPageFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ComicPage: View {
    let directory: URL
    let format: ComicBook.Format
    let document: PDFDocument?
    let index: Int
    let fit: Bool
    let trimBorders: Bool
    let scale: String
    var zoomStart = "center"
    let cacheVersion: Int
    var placeholderAspect: CGFloat?
    var half: Int?
    var stackSpread = false
    var rightFirst = false
    var spreadGap: CGFloat = 0
    var onDoubleTap: () -> Void = {}
    let onAction: (String, UIImage) -> Void
    let onTap: (CGPoint) -> Void
    @AppStorage("reader.longTap", store: YokaiStorage.defaults) private var longTap = true
    @State private var image: UIImage?
    @State private var originalImage: UIImage?
    @State private var aspect: CGFloat = 1

    var body: some View {
        Group {
            if let image {
                if fit {
                    ZoomableImage(image: image, scale: scale, zoomStart: zoomStart, onTap: onTap)
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .gesture(SpatialTapGesture(count: 2, coordinateSpace: .named("reader"))
                            .exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: .named("reader")))
                            .onEnded { value in switch value { case .first: onDoubleTap(); case .second(let event): onTap(event.location) } })
                }
            } else {
                Rectangle().fill(Color.clear).aspectRatio(placeholderAspect ?? aspect, contentMode: .fit).overlay(ProgressView().tint(.gray))
            }
        }
        .contextMenu {
            if longTap, let image = originalImage {
                Button("保存图片", systemImage: "square.and.arrow.down") { onAction("save", image) }
                Button("分享图片", systemImage: "square.and.arrow.up") { onAction("share", image) }
                Button("设为封面", systemImage: "photo") { onAction("cover", image) }
            }
        }
        .accessibilityLabel("第 \(index + 1) 页")
        .task(id: "\(directory.path)-\(index)-\(trimBorders)-\(cacheVersion)-\(half ?? -1)-\(stackSpread)-\(rightFirst)-\(spreadGap)") {
            let identity = "\(directory.path)/\(index)-\(half ?? -1)-\(stackSpread)-\(rightFirst)-\(spreadGap)"
            guard image == nil || appliedTrim != trimBorders || loadedIdentity != identity else { return }
            image = nil; originalImage = nil; loadedIdentity = identity
            if format == .pdf, let pdfPage = document?.page(at: index) {
                let bounds = pdfPage.bounds(for: .mediaBox)
                let width = min(UIScreen.main.bounds.width * UIScreen.main.scale, 1800)
                image = pdfPage.thumbnail(of: CGSize(width: width, height: width * bounds.height / max(bounds.width, 1)), for: .mediaBox)
            } else if format == .images {
                image = await Task.detached(priority: .userInitiated) {
                    ChapterArchive.image(directory: directory, index: index)
                }.value
            }
            originalImage = image
            if let half { image = image?.spreadHalf(half) }
            if stackSpread, let loaded = image { image = await Task.detached { loaded.stackingSpread(rightFirst: rightFirst, gap: spreadGap) }.value }
            if trimBorders, let loaded = image { image = await Task.detached { loaded.trimmingBorders() }.value }
            if let image { aspect = image.size.width / max(image.size.height, 1) }
            appliedTrim = trimBorders
        }
        .onDisappear { image = nil; originalImage = nil }
    }
    @State private var appliedTrim = false
    @State private var loadedIdentity = ""
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var scale = "fit"
    var zoomStart = "center"
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 5
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.imageView.contentMode = .scaleAspectFit
        view.addSubview(view.imageView)
        context.coordinator.imageView = view.imageView
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap(_:)))
        single.require(toFail: tap)
        view.addGestureRecognizer(single)
        context.coordinator.onTap = onTap
        return view
    }

    func updateUIView(_ view: ImageScrollView, context: Context) {
        context.coordinator.onTap = onTap
        let changed = view.imageView.image !== image || view.scaleMode != scale || view.zoomStart != zoomStart
        view.scaleMode = scale; view.zoomStart = zoomStart
        view.clipsToBounds = true
        if changed {
            view.setZoomScale(1, animated: false)
            view.imageView.image = image
            view.relayout = true; view.setNeedsLayout()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onTap: ((CGPoint) -> Void)?
        @objc func singleTap(_ gesture: UITapGestureRecognizer) {
            onTap?(gesture.location(in: gesture.view?.window))
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView else { return }
            imageView.center = CGPoint(x: max(scrollView.contentSize.width, scrollView.bounds.width) / 2,
                                       y: max(scrollView.contentSize.height, scrollView.bounds.height) / 2)
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

private final class ImageScrollView: UIScrollView {
    let imageView = UIImageView()
    var scaleMode = "fit"
    var zoomStart = "center"
    var relayout = true
    private var previousSize: CGSize = .zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize || relayout {
            guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
            relayout = false
            previousSize = bounds.size
            zoomScale = 1
            let sx = bounds.width / max(image.size.width, 1), sy = bounds.height / max(image.size.height, 1)
            let ratio: CGFloat
            switch scaleMode {
            case "fill": ratio = max(sx, sy)
            case "width": ratio = sx
            case "height": ratio = sy
            case "original": ratio = 1 / (window?.screen.scale ?? UIScreen.main.scale)
            case "smart": ratio = image.size.height > image.size.width ? sx : sy
            default: ratio = min(sx, sy)
            }
            let size = scaleMode == "stretch" ? bounds.size : CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            imageView.contentMode = .scaleToFill
            imageView.frame = CGRect(origin: CGPoint(x: max(0, (bounds.width - size.width) / 2), y: max(0, (bounds.height - size.height) / 2)), size: size)
            contentSize = CGSize(width: max(bounds.width, size.width), height: max(bounds.height, size.height))
            let extra = max(0, size.width - bounds.width)
            contentOffset = CGPoint(x: zoomStart == "right" ? extra : zoomStart == "left" ? 0 : extra / 2, y: 0)
        }
    }
}
