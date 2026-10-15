import XCTest

// Proves the app launches under XCUITest. The real viewer smoke test arrives with the password
// prompt and error handling.
final class LaunchTests: XCTestCase {
    @MainActor
    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
    }
}
