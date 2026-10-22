import XCTest
import UIKit

final class HubFlowTests: XCTestCase {
    func testAnimatedWebPInContinuousReader() throws { try checkAnimatedReader(mode: "webtoon") }
    func testAnimatedWebPInPagedReader() throws { try checkAnimatedReader(mode: "ltr") }

    private func checkAnimatedReader(mode: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-YokaiLocalUIFixture", "-YokaiAnimationCheck"]
        app.launchEnvironment["YOKAI_ANIMATION_MODE"] = mode
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Yōkai · 漫画"].waitForExistence(timeout: 15))
        app.buttons["Yōkai · 漫画"].tap()
        if app.alerts.firstMatch.exists { XCTFail(app.alerts.firstMatch.debugDescription); return }
        app.buttons["书架"].firstMatch.tap()
        let book = app.staticTexts["动图播放验证"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10), app.debugDescription)
        book.tap()
        app.buttons["开始阅读"].tap()
        XCTAssertTrue(app.staticTexts["readerPage"].waitForExistence(timeout: 5))
        assertAnimatedPixels(app)
        // The same image must resume after the host propagates foreground state.
        XCUIDevice.shared.press(.home)
        app.activate()
        assertAnimatedPixels(app)
        if mode == "ltr" {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
            assertAnimatedPixels(app)
        }
    }

    private func assertAnimatedPixels(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        var colors = Set<String>()
        for _ in 0..<8 {
            let image = app.screenshot().image.cgImage!
            let sample = image.cropping(to: CGRect(x: image.width / 2, y: image.height * 2 / 5, width: 1, height: 1))!
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            if pixel[0] > 180 && pixel[2] < 60 { colors.insert("red") }
            if pixel[2] > 180 && pixel[0] < 60 { colors.insert("blue") }
            if colors.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.13)
        }
        XCTAssertEqual(colors, ["red", "blue"], "Rendered pixels must change between both animation frames", file: file, line: line)
    }

    func testLatestCoverSearch() throws {
        try runQiyeScript("cover-search-script")
    }

    func testLatestReaderLifecycle() throws {
        try runQiyeScript("reader-lifecycle-script")
    }

    func testLatestBookManagement() throws {
        try runQiyeScript("book-management-script")
    }

    func testLatestSubscriptionReading() throws {
        try runQiyeScript("subscription-reading-script")
    }

    private func runQiyeScript(_ name: String) throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "js"))
        let bootstrap = #"""
        const wait=async(fn,ms=45000)=>{const until=Date.now()+ms;while(Date.now()<until){if(await fn())return;await new Promise(r=>setTimeout(r,150))}throw Error('Wait timed out: '+fn.toString())};
        const $=s=>document.querySelector(s);const check=(value,message)=>{if(!value)throw Error(message)};
        await wait(()=>$('#import-books'));const {api}=await import('./bridge.js');
        """#
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["QIYE_TEST_SCRIPT"] = bootstrap + (try String(contentsOf: url, encoding: .utf8))
        app.launch()
        defer { app.terminate() }
        let result = app.staticTexts["qiye-test-result"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            result.exists && (result.label == "PASS" || result.label.hasPrefix("ERROR:"))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 180), .completed)
        XCTAssertEqual(result.label, "PASS", result.label)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testBrowseSearchSubmitsAcrossSources() throws {
        let app = launchSearchFixture()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("needle\n")
        XCTAssertTrue(app.navigationBars["全局搜索"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["needle-search-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["needle-search-0"].exists, "A slow source must not block faster sources")
        XCTAssertTrue(app.staticTexts["测试图源连接失败"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["needle-search-5"].waitForExistence(timeout: 3), "Sources beyond the first five must also run")
    }

    func testBrowseSearchLinkAndSourceSearch() throws {
        let app = launchSearchFixture()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("needle")
        let action = app.buttons["全局搜索“needle”"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(app.staticTexts["needle-search-1"].waitForExistence(timeout: 3))
        app.buttons.matching(identifier: "在此图源继续搜索").element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["搜索验证图源1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["needle-search-1"].waitForExistence(timeout: 3))
        let sourceField = app.searchFields.firstMatch
        if !sourceField.exists { app.swipeDown() }
        XCTAssertTrue(sourceField.waitForExistence(timeout: 5), app.debugDescription)
        sourceField.tap()
        sourceField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "needle".count) + "revised\n")
        XCTAssertTrue(app.staticTexts["revised-search-1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["搜索验证图源1"].exists, "Submitting within a source must not trigger the parent global search")
    }

    private let metadataTitle = "复制验证：在遥远星空下与伙伴一起寻找失落书页的漫长旅程——这是一段超过详情标题显示行数的完整标题，包含空格 Full Title & 最后不能遗漏的尾声"
    private let metadataAuthor = "作者甲 / Author A"
    private let metadataArtist = "画师乙 / Artist B"

    func testMangaMetadataSearchAndReturn() throws {
        let app = launchMetadataDetails()
        defer { app.terminate() }
        for (identifier, label, text) in [("manga-title", "标题", metadataTitle), ("manga-author", "作者", metadataAuthor), ("manga-artist", "画师", metadataArtist)] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 5))
            XCTAssertEqual(control.label, "\(label)：\(text)")
            control.tap()
            assertMetadataSearch(app, query: text)
            returnToMetadataDetails(app)
        }
        app.buttons["manga-artist"].press(forDuration: 1)
        let search = app.buttons["全局搜索"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        assertMetadataSearch(app, query: metadataArtist)
        returnToMetadataDetails(app)
    }

    func testMangaMetadataCopiesCompleteText() throws {
        let app = launchMetadataDetails()
        defer { app.terminate() }
        for (identifier, menu, text) in [("manga-title", "复制标题", metadataTitle),
                                         ("manga-author", "复制作者", metadataAuthor),
                                         ("manga-artist", "复制画师", metadataArtist)] {
            assertMetadataCopy(app, identifier: identifier, menu: menu, text: text)
            returnToMetadataDetails(app)
        }
    }

    func testMangaEmptyMetadataHidesActions() throws {
        let app = launchMetadataDetails(title: "空元数据验证")
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["暂无章节"].waitForExistence(timeout: 5), "Wait for the details response before checking absent fields")
        XCTAssertFalse(app.buttons["manga-author"].exists, "An empty author must not create a search/copy action")
        XCTAssertFalse(app.buttons["manga-artist"].exists, "An omitted artist must not create a search/copy action")
        app.buttons["manga-title"].tap()
        assertMetadataSearch(app, query: "空元数据验证")
    }

    func testStoredMangaMetadataSearchAndCopy() throws {
        let app = launchSearchFixture("-YokaiMetadataCheck")
        defer { app.terminate() }
        app.buttons["书架"].firstMatch.tap()
        for (title, sourceLabel) in [("复制验证本地漫画", "本地图源"), ("复制验证缺失图源漫画", "图源插件尚未安装")] {
            let book = app.staticTexts[title].firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 10))
            book.tap()
            XCTAssertTrue(app.staticTexts[sourceLabel].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["manga-author"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["manga-artist"].label, "画师：\(metadataArtist)")
            app.buttons["manga-author"].tap()
            assertMetadataSearch(app, query: metadataAuthor)
            returnToMetadataDetails(app)
            assertMetadataCopy(app, identifier: "manga-title", menu: "复制标题", text: title)
            returnToMetadataDetails(app)
            app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["书架"].waitForExistence(timeout: 5))
        }
    }

    func testMangaScanlatorIncludesExcludesAndReset() throws {
        let app = launchMetadataFeatureBrowse()
        defer { app.terminate() }
        app.buttons["browse-manga-/metadata/features"].tap()
        assertDetailsRequests(app, count: 1)
        assertFeatureChapters(app, visible: ["a", "b", "c", "unknown"])
        app.buttons["chapterFiltersButton"].tap()
        selectScanlator(app, name: "汉化组甲", option: "包含")
        selectScanlator(app, name: "汉化组乙", option: "包含")
        app.buttons["完成"].tap()
        assertFeatureChapters(app, visible: ["a", "b"], hidden: ["c", "unknown"])
        app.buttons["chapterFiltersButton"].tap()
        selectScanlator(app, name: "汉化组甲", option: "排除")
        selectScanlator(app, name: "汉化组乙", option: "排除")
        app.buttons["完成"].tap()
        assertFeatureChapters(app, visible: ["c", "unknown"], hidden: ["a", "b"])
        app.buttons["chapterFiltersButton"].tap()
        let reset = app.buttons["scanlatorFiltersReset"]
        for _ in 0..<4 {
            if reset.exists && reset.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(reset.waitForExistence(timeout: 3), app.debugDescription)
        reset.tap()
        app.buttons["完成"].tap()
        assertFeatureChapters(app, visible: ["a", "b", "c", "unknown"])
    }

    func testBrowseFavoriteGenreActionsAndPinnedSearchOrder() throws {
        let app = launchMetadataFeatureBrowse()
        defer { app.terminate() }
        let manga = app.buttons["browse-manga-/metadata/features"]
        manga.press(forDuration: 1)
        let favorite = app.buttons["browseFavorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        XCTAssertEqual(favorite.label, "加入书架")
        favorite.tap()
        manga.tap()
        XCTAssertTrue(app.buttons["已在书架"].waitForExistence(timeout: 5))
        let genre = app.buttons["manga-genre-冒险"]
        XCTAssertTrue(genre.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "manga-genre-冒险").count, 1, "Repeated genres must form one tag")
        genre.tap()
        assertMetadataSearch(app, query: "冒险", sourceID: "metadata-features-1")
        let headers = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "globalSearchSource-"))
        XCTAssertTrue(headers.element(boundBy: 2).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual((0..<3).map { headers.element(boundBy: $0).identifier },
                       ["globalSearchSource-metadata-features-3", "globalSearchSource-metadata-features-1", "globalSearchSource-metadata-features-0"],
                       "Pinned sources precede reading activity, which precedes unused sources")
        returnToMetadataDetails(app)
        assertMetadataCopy(app, identifier: "manga-genre-科幻", menu: "复制标签", text: "科幻", sourceID: "metadata-features-1")
        returnToMetadataDetails(app)
        app.navigationBars.firstMatch.buttons["BackButton"].tap()
        XCTAssertTrue(manga.waitForExistence(timeout: 5))
        manga.press(forDuration: 1)
        XCTAssertTrue(favorite.waitForExistence(timeout: 3))
        XCTAssertEqual(favorite.label, "移出书架")
        favorite.tap()
        manga.tap()
        XCTAssertTrue(app.buttons["加入书架"].waitForExistence(timeout: 5), "Removing from browse must update the same book's favorite state")
    }

    func testMangaDetailsRefreshPolicyAndManualRefresh() throws {
        let app = launchMetadataFeatureBrowse()
        defer { app.terminate() }
        app.buttons["browse-manga-/metadata/features"].tap()
        assertDetailsRequests(app, count: 1)
        reopenFeatureDetails(app)
        assertDetailsRequests(app, count: 1, unchanged: true)
        openDetailsRefreshSettings(app)
        let interval = app.buttons["detailsRefreshInterval"]
        XCTAssertTrue([interval.label, interval.value as? String ?? ""].joined().contains("15 分钟"))
        chooseMenuOption(app, identifier: "detailsRefreshInterval", option: "每次进入")
        app.buttons["完成"].tap()
        reopenFeatureDetails(app)
        assertDetailsRequests(app, count: 2)
        openDetailsRefreshSettings(app)
        let automatic = app.switches["detailsAutoRefresh"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 3), app.debugDescription)
        automatic.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: automatic)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 3), .completed, app.debugDescription)
        XCTAssertEqual(automatic.value as? String, "0", app.debugDescription)
        XCTAssertFalse(interval.isEnabled)
        app.buttons["完成"].tap()
        reopenFeatureDetails(app)
        assertDetailsRequests(app, count: 2, unchanged: true)
        app.buttons["chapterActionsMenu"].tap()
        app.buttons["detailsRefreshNow"].tap()
        assertDetailsRequests(app, count: 3)
        reopenFeatureDetails(app, path: "/metadata/features-cold")
        assertDetailsRequests(app, count: 1)
        reopenFeatureDetails(app, path: "/metadata/features-cold")
        assertDetailsRequests(app, count: 1, unchanged: true)
    }

    private func launchMetadataFeatureBrowse() -> XCUIApplication {
        let app = launchSearchFixture("-YokaiMetadataFeaturesCheck")
        let source = app.buttons["source-metadata-features-1"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        XCTAssertTrue(app.buttons["browse-manga-/metadata/features"].waitForExistence(timeout: 5))
        return app
    }

    private func selectScanlator(_ app: XCUIApplication, name: String, option: String) {
        let picker = app.buttons["scanlator-" + name]
        for _ in 0..<4 {
            if picker.exists && picker.isHittable { break }
            app.swipeUp()
        }
        chooseMenuOption(app, identifier: "scanlator-" + name, option: option)
    }

    private func assertFeatureChapters(_ app: XCUIApplication, visible: [String], hidden: [String] = []) {
        app.swipeUp()
        for suffix in visible {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chapter-/metadata/features/" + suffix).firstMatch.waitForExistence(timeout: 5), suffix + "\n" + app.debugDescription)
        }
        for suffix in hidden {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "chapter-/metadata/features/" + suffix).firstMatch.exists, suffix + "\n" + app.debugDescription)
        }
    }

    private func reopenFeatureDetails(_ app: XCUIApplication, path: String = "/metadata/features") {
        app.navigationBars.firstMatch.buttons["BackButton"].tap()
        let manga = app.buttons["browse-manga-" + path]
        XCTAssertTrue(manga.waitForExistence(timeout: 5), app.debugDescription)
        manga.tap()
    }

    private func openDetailsRefreshSettings(_ app: XCUIApplication) {
        app.buttons["chapterActionsMenu"].tap()
        app.buttons["detailsRefreshSettings"].tap()
        XCTAssertTrue(app.navigationBars["详情刷新"].waitForExistence(timeout: 5), app.debugDescription)
    }

    private func assertDetailsRequests(_ app: XCUIApplication, count: Int, unchanged: Bool = false) {
        XCTAssertTrue(app.staticTexts["详情请求次数：\(count)"].waitForExistence(timeout: 5), app.debugDescription)
        if unchanged {
            let extraRequest = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.staticTexts["详情请求次数：\(count + 1)"].exists
            }, object: nil)
            extraRequest.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [extraRequest], timeout: 1.5), .completed, "Entering with a valid cache must not call details again")
            XCTAssertTrue(app.staticTexts["详情请求次数：\(count)"].exists, app.debugDescription)
        }
    }

    func testLibrarySourceFiltersIncludeExcludeAndClear() throws {
        let app = launchSearchFixture("-YokaiLibrarySourceFilterCheck")
        defer { app.terminate() }
        app.buttons["书架"].firstMatch.tap()
        if app.buttons["清除图源筛选"].exists { app.buttons["清除图源筛选"].tap() }
        let local = "复制验证本地漫画", missing = "复制验证缺失图源漫画"
        let first = "复制验证图源漫画-search-1", second = "复制验证图源漫画-search-3"
        assertShelfTitles(app, visible: [local, missing, first, second])

        app.buttons["筛选与显示"].tap()
        selectLibrarySourceFilter(app, source: "搜索验证图源1（zh）", selection: "包含")
        selectLibrarySourceFilter(app, source: "搜索验证图源3（zh）", selection: "包含")
        app.buttons["完成"].tap()
        assertShelfTitles(app, visible: [first, second], hidden: [local, missing])
        XCTAssertTrue(app.buttons["图源筛选已启用"].exists)

        app.buttons["图源筛选已启用"].tap()
        selectLibrarySourceFilter(app, source: "搜索验证图源1（zh）", selection: "排除")
        selectLibrarySourceFilter(app, source: "搜索验证图源3（zh）", selection: "不限")
        app.buttons["完成"].tap()
        assertShelfTitles(app, visible: [local, missing, second], hidden: [first])

        app.buttons["清除图源筛选"].tap()
        assertShelfTitles(app, visible: [local, missing, first, second])
        XCTAssertFalse(app.buttons["图源筛选已启用"].exists)
    }

    private func selectLibrarySourceFilter(_ app: XCUIApplication, source: String, selection: String) {
        XCTAssertTrue(app.navigationBars["书架显示与筛选"].waitForExistence(timeout: 5))
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", source)).firstMatch
        for _ in 0..<4 {
            if picker.exists && picker.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 3), app.debugDescription)
        picker.tap()
        let option = app.buttons[selection]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
    }

    private func assertShelfTitles(_ app: XCUIApplication, visible: [String], hidden: [String] = [],
                                   file: StaticString = #filePath, line: UInt = #line) {
        for title in visible { XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 5), title, file: file, line: line) }
        for title in hidden { XCTAssertFalse(app.staticTexts[title].exists, title, file: file, line: line) }
    }

    private func launchMetadataDetails(title: String? = nil) -> XCUIApplication {
        let app = launchSearchFixture("-YokaiMetadataCheck")
        let source = app.buttons["source-search-1"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()
        let manga = app.staticTexts[title ?? metadataTitle].firstMatch
        XCTAssertTrue(manga.waitForExistence(timeout: 5))
        manga.tap()
        XCTAssertTrue(app.buttons["manga-title"].waitForExistence(timeout: 5))
        return app
    }

    private func assertMetadataSearch(_ app: XCUIApplication, query: String, sourceID: String = "search-1", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars["全局搜索"].waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        XCTAssertTrue(app.staticTexts["\(query)-\(sourceID)"].waitForExistence(timeout: 5), "The complete metadata text must reach source search\n\(app.debugDescription)", file: file, line: line)
    }

    private func returnToMetadataDetails(_ app: XCUIApplication) {
        let navigation = app.navigationBars["全局搜索"]
        let closeSearch = navigation.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "取消", "Cancel"])).firstMatch
        if closeSearch.exists { closeSearch.tap() }
        let back = navigation.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.buttons["manga-title"].waitForExistence(timeout: 5))
    }

    private func assertMetadataCopy(_ app: XCUIApplication, identifier: String, menu: String, text: String, sourceID: String = "search-1",
                                    file: StaticString = #filePath, line: UInt = #line) {
        app.buttons[identifier].press(forDuration: 1)
        let copy = app.buttons[menu]
        XCTAssertTrue(copy.waitForExistence(timeout: 3), file: file, line: line)
        copy.tap()
        app.buttons[identifier].tap()
        assertMetadataSearch(app, query: text, sourceID: sourceID, file: file, line: line)
        let field = app.searchFields.firstMatch
        if !field.exists || !field.isHittable { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        field.tap()
        let clear = field.buttons.firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 3), file: file, line: line)
        clear.tap()
        XCTAssertTrue((field.value as? String ?? "").isEmpty || field.value as? String == field.placeholderValue,
                      "Clear the prefilled query before testing the clipboard", file: file, line: line)
        field.press(forDuration: 1)
        let pasteLabels = NSPredicate(format: "label IN %@", ["粘贴", "Paste"])
        let pasteButton = app.buttons.matching(pasteLabels).firstMatch
        let paste = pasteButton.waitForExistence(timeout: 2) ? pasteButton : app.menuItems.matching(pasteLabels).firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 3), file: file, line: line)
        paste.tap()
        let pasted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 3), .completed, "Copy must preserve the entire field, including the title's hidden suffix", file: file, line: line)
        field.typeText("\n")
        assertMetadataSearch(app, query: text, sourceID: sourceID, file: file, line: line)
    }

    func testReaderToolbarAndIndependentTapZones() throws {
        let app = launchReaderFixture()
        defer { app.terminate() }
        app.buttons["readerSettingsMenu"].tap()
        app.buttons["readerToolbarSettings"].tap()
        let editor = app.collectionViews["readerToolbarEditor"]
        let removeRow = editor.cells.containing(.button, identifier: "Reorder 自动滚动").firstMatch
        XCTAssertTrue(removeRow.waitForExistence(timeout: 5), app.debugDescription)
        removeRow.images.matching(identifier: "minus.circle.fill").firstMatch.tap()
        let confirmDelete = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "删除"])).firstMatch
        if confirmDelete.waitForExistence(timeout: 2) { confirmDelete.tap() }
        XCTAssertTrue(app.buttons["readerToolbarAdd.autoScroll"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["readerToolbarAdd.tapZones"].tap()
        let firstRow = editor.cells.containing(.button, identifier: "Reorder 书签").firstMatch
        let reorder = editor.buttons["Reorder 点按区域"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 3), app.debugDescription)
        reorder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        app.buttons["完成"].tap()
        let tapZones = app.buttons["readerToolbar.tapZones"]
        XCTAssertTrue(tapZones.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["readerToolbar.autoScroll"].exists)
        XCTAssertLessThan(tapZones.frame.minX, app.buttons["readerToolbar.bookmark"].frame.minX)
        tapZones.tap()
        chooseMenuOption(app, identifier: "tapZonePreset", option: "自定义")
        chooseMenuOption(app, identifier: "tapZoneLayout", option: "上下三区")
        chooseMenuOption(app, identifier: "tapZone.0", option: "无操作")
        chooseMenuOption(app, identifier: "tapZoneReaderMode", option: "翻页阅读")
        chooseMenuOption(app, identifier: "tapZonePreset", option: "自定义")
        chooseMenuOption(app, identifier: "tapZoneLayout", option: "九宫格")
        chooseMenuOption(app, identifier: "tapZone.0", option: "下一页")
        chooseMenuOption(app, identifier: "tapZoneReaderMode", option: "连续阅读")
        let layout = app.buttons["tapZoneLayout"]
        XCTAssertTrue([layout.label, layout.value as? String ?? ""].joined().contains("上下三区"))
        XCTAssertEqual(app.buttons["tapZone.0"].label, "无操作")
        chooseMenuOption(app, identifier: "tapZoneReaderMode", option: "翻页阅读")
        XCTAssertTrue([layout.label, layout.value as? String ?? ""].joined().contains("九宫格"))
        XCTAssertEqual(app.buttons["tapZone.0"].label, "下一页")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["关闭阅读器"].waitForExistence(timeout: 5))
    }

    func testReaderEdgeHoldStopsAndCenterMenuRemains() throws {
        let app = launchReaderFixture()
        defer { app.terminate() }
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "第 2 页")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["readerSettingsMenu"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        let before = page.frame.minY
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 12, dy: 0))
        edge.press(forDuration: 2)
        let stopped = page.frame.minY
        XCTAssertLessThan(stopped, before - 80, "A stationary edge hold must scroll the images")
        XCTAssertFalse(app.buttons["保存图片"].exists, "The edge hold must not open the image menu")
        let drift = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(page.frame.minY - stopped) > 2 }, object: nil)
        drift.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [drift], timeout: 1.5), .completed, "Releasing the edge must stop scrolling")
        center.press(forDuration: 1)
        XCTAssertTrue(app.buttons["保存图片"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["分享图片"].exists)
    }

    func testReaderBackgroundReturnPreservesPosition() throws {
        let app = launchReaderFixture()
        defer { app.terminate() }
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "第 2 页")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let before = page.frame.minY
        let autoScroll = app.buttons["readerToolbar.autoScroll"]
        autoScroll.tap()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.frame.minY < before - 80 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "Automatic scrolling must move the reader before backgrounding")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(autoScroll.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(autoScroll.label, "开始自动滚动", "Backgrounding must stop automatic scrolling")
        let position = page.frame.minY
        XCTAssertLessThan(position, before - 80, "Returning must retain the scrolled position")
        let drift = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(page.frame.minY - position) > 2 }, object: nil)
        drift.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [drift], timeout: 1.5), .completed, "Returning must leave automatic scrolling stopped")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["关闭阅读器"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(page.frame.minY, position, accuracy: 2, "A stopped reader must preserve its exact position across background and return")
    }

    func testReaderBadImageRetryAndTextFallback() throws {
        let app = launchSearchFixture("-YokaiReaderImageCheck")
        defer { app.terminate() }
        app.buttons["书架"].firstMatch.tap()
        let book = app.staticTexts["坏图与文字验证"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        let read = app.buttons["开始阅读 · 修复验证章节"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        let error = app.descendants(matching: .any).matching(identifier: "readerPageError.0").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["图片无法解码"].exists)
        XCTAssertTrue(app.buttons["readerPageOpenWeb.0"].exists)
        app.buttons["readerPageRetry.0"].tap()
        let page = app.images.matching(NSPredicate(format: "label == %@", "第 1 页")).firstMatch
        let repaired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in page.exists && !error.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [repaired], timeout: 8), .completed, app.debugDescription)
        page.press(forDuration: 1)
        XCTAssertTrue(app.buttons["readerChapterWeb"].waitForExistence(timeout: 3))
        app.buttons["readerImageText"].tap()
        XCTAssertTrue(app.navigationBars["图片文字"].waitForExistence(timeout: 5), app.debugDescription)
        let fallback = app.staticTexts.matching(NSPredicate(format: "label IN %@ OR label BEGINSWITH %@",
            ["此设备不支持实况文本", "系统版本不支持实况文本", "未识别到文字。"], "文字识别失败：")).firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 10), "The text-free fixture must reach a clear OCR fallback\n" + app.debugDescription)
        let copy = app.buttons["readerImageTextCopyAll"]
        XCTAssertFalse(copy.exists && copy.isEnabled)
        app.buttons["readerImageTextDone"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertFalse(error.exists)
    }

    func testHistorySearchAndScrollBeyondFirstBatch() throws {
        let app = launchSearchFixture("-YokaiHistoryBatchCheck")
        defer { app.terminate() }
        app.buttons["最近"].firstMatch.tap()
        app.segmentedControls.buttons["历史"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("历史批次\n")
        XCTAssertTrue(app.staticTexts["历史批次 000"].waitForExistence(timeout: 5))
        let oldest = app.staticTexts["历史批次 064"]
        XCTAssertFalse(oldest.exists, "The oldest entry starts outside the first batch")
        field.tap(); field.buttons.firstMatch.tap(); field.typeText("历史批次 064\n")
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "Search must include records not rendered in the first batch")
        oldest.tap()
        XCTAssertTrue(app.buttons["manga-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["manga-title"].label, "标题：历史批次 064")
        app.navigationBars.firstMatch.buttons["BackButton"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.buttons.firstMatch.tap(); field.typeText("历史批次\n")
        for _ in 0..<20 {
            if oldest.exists && oldest.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(oldest.exists && oldest.isHittable, "Scrolling must append records beyond the initial 50")
    }

    private func launchReaderFixture() -> XCUIApplication {
        let app = launchSearchFixture("-YokaiReaderInteractionCheck")
        app.buttons["书架"].firstMatch.tap()
        let book = app.staticTexts["阅读手势验证"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        let read = app.buttons["开始阅读"]
        XCTAssertTrue(read.waitForExistence(timeout: 5))
        read.tap()
        XCTAssertTrue(app.staticTexts["readerPage"].waitForExistence(timeout: 5))
        return app
    }

    private func chooseMenuOption(_ app: XCUIApplication, identifier: String, option: String) {
        let control = app.buttons[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        control.tap()
        // The preview grid repeats action names; only the menu has no tapZone.n identifier.
        let choice = app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH %@)", option, "tapZone.")).element
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(choice.isHittable, app.debugDescription)
        choice.tap()
    }

    func testSourceAndPluginSettingsRemainAccessible() throws {
        let app = launchSearchFixture("-YokaiSourceNavigationCheck")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("needle")
        XCTAssertTrue(app.buttons["source-navigation-0"].exists, "A manga query must not hide installed sources")
        let filter = app.textFields["筛选图源名称"]
        filter.tap(); filter.typeText("配置验证图源0")
        XCTAssertTrue(app.buttons["source-navigation-0"].exists)
        XCTAssertFalse(app.buttons["source-navigation-1"].exists)
        filter.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "配置验证图源0".count))
        XCTAssertTrue(app.buttons["source-navigation-1"].exists)
        app.buttons["配置验证图源0设置"].tap()
        XCTAssertTrue(app.textFields["用户名"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        app.buttons["完成"].tap()
        app.buttons["source-navigation-0"].tap()
        XCTAssertTrue(app.staticTexts["图源目录验证"].waitForExistence(timeout: 5))
        app.navigationBars.firstMatch.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["source-navigation-0"].waitForExistence(timeout: 5))
        app.buttons["插件"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "extension-")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["插件信息"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "账号与图源设置").count, 2, "Every source in a multi-source plugin must expose its settings")
        app.buttons.matching(identifier: "账号与图源设置").element(boundBy: 1).tap()
        XCTAssertTrue(app.textFields["用户名"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        app.buttons["完成"].tap()
        app.buttons.matching(identifier: "浏览图源").element(boundBy: 1).tap()
        XCTAssertTrue(app.navigationBars["配置验证图源1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["图源目录验证"].waitForExistence(timeout: 5))
    }

    private func launchSearchFixture(_ check: String = "-YokaiGlobalSearchCheck") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YokaiLocalUIFixture", check]
        app.launch()
        XCTAssertTrue(app.buttons["Yōkai · 漫画"].waitForExistence(timeout: 15))
        app.buttons["Yōkai · 漫画"].tap()
        app.buttons["浏览"].firstMatch.tap()
        return app
    }

    func testReadersAndDirectURLs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-host-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["栖页 · 阅读"].waitForExistence(timeout: 15))
        app.buttons["栖页 · 阅读"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导入")).firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["切换阅读器"].exists)
        app.buttons["切换阅读器"].tap()
        XCTAssertTrue(app.buttons["Yōkai · 漫画"].waitForExistence(timeout: 10))
        app.open(URL(string: "readinghub://yokai")!)
        XCTAssertTrue(app.buttons["浏览"].firstMatch.waitForExistence(timeout: 20))
        app.open(URL(string: "readinghub://qiye")!)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导入")).firstMatch.waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "host-qiye"; shot.lifetime = .keepAlways; add(shot)
    }
}
