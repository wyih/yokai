import XCTest

final class HubFlowTests: XCTestCase {
    func testReadersAndDirectURLs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reader-host-ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["栖页 · 阅读"].waitForExistence(timeout: 15))
        app.buttons["栖页 · 阅读"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["切换阅读器"].exists)
        app.buttons["切换阅读器"].tap()
        XCTAssertTrue(app.buttons["Yōkai · 漫画"].waitForExistence(timeout: 10))
        app.open(URL(string: "readinghub://yokai")!)
        XCTAssertTrue(app.tabBars.buttons["浏览"].waitForExistence(timeout: 20))
        app.open(URL(string: "readinghub://qiye")!)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "host-qiye"; shot.lifetime = .keepAlways; add(shot)
    }
}
