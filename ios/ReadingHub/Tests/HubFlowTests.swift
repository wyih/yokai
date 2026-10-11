import XCTest

final class HubFlowTests: XCTestCase {
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
