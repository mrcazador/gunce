import XCTest

/// Walks the main screens on invented demo data and attaches a screenshot of each.
/// CI exports the attachments so the layout can be reviewed without a device.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testLight() { walk(prefix: "light", extra: []) }

    func testDark() { walk(prefix: "dark", extra: ["-demo-dark"]) }

    func testLargeText() {
        walk(prefix: "xl", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
    }

    func testSignIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-signed-out"]
        app.launch()
        snap("signin")
    }

    private func walk(prefix: String, extra: [String]) {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + extra
        app.launch()

        snap("\(prefix)-01-simdi")
        app.swipeUp()
        snap("\(prefix)-02-simdi-scrolled")
        app.swipeDown()

        if tap(app.buttons["Park et"].firstMatch) {
            snap("\(prefix)-03-park-sheet")
            tap(app.buttons["Vazgeç"].firstMatch)
        }

        if tap(app.buttons["Yeni görev ekle"].firstMatch) {
            app.typeText("Faturayı öde")
            snap("\(prefix)-04-capture")
            tap(app.buttons["Vazgeç"].firstMatch)
        }

        if tap(app.buttons["Ayarlar"].firstMatch) {
            snap("\(prefix)-05-ayarlar")
            if tap(app.staticTexts["Profilim"].firstMatch) {
                snap("\(prefix)-06-profil")
                tap(app.navigationBars.buttons.firstMatch)
            }
            tap(app.buttons["Bitti"].firstMatch)
        }

        if tap(app.tabBars.buttons["Görevler"].firstMatch) {
            snap("\(prefix)-07-gorevler")
            if tap(app.staticTexts["Çeyrek sunumunu hazırla"].firstMatch) {
                snap("\(prefix)-08-detay")
                app.swipeUp()
                snap("\(prefix)-09-detay-adimlar")
                if tap(app.buttons["Diğer"].firstMatch) {
                    snap("\(prefix)-10-detay-menu")
                    app.tap()
                }
            }
        }

        if tap(app.tabBars.buttons["Bugün"].firstMatch) {
            snap("\(prefix)-11-bugun")
        }

        if tap(app.tabBars.buttons["Ara"].firstMatch) {
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 3) {
                field.tap()
                field.typeText("kira")
            }
            snap("\(prefix)-12-ara")
        }
    }

    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5), element.isHittable else { return false }
        element.tap()
        return true
    }

    private func snap(_ name: String) {
        // Let animations settle so the capture shows the final state.
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
