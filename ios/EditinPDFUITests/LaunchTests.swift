import XCTest

// Proves the app launches under XCUITest, with nothing asked of it. What it does with documents is
// ViewerSmokeTests'.
final class LaunchTests: XCTestCase {
    @MainActor
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
