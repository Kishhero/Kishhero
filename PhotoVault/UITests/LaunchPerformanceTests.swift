import XCTest

/// Cold launch time, measured by Xcode the way the system measures it.
/// Target: well under 2 seconds on a mid-range iPhone. Launch does no
/// cryptography; it only checks whether the vault exists and shows the
/// keypad. Run on a real device with the Release configuration.
final class LaunchPerformanceTests: XCTestCase {
    @MainActor
    func testLaunchTime() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// The first screen is always the setup or lock screen: nothing from the
    /// vault is visible before the passcode.
    @MainActor
    func testLaunchShowsNoVaultContent() {
        let app = XCUIApplication()
        app.launch()
        let lockScreen = app.staticTexts["Enter Passcode"]
        let setupScreen = app.staticTexts["PhotoVault"]
        XCTAssertTrue(lockScreen.waitForExistence(timeout: 5) || setupScreen.exists)
        XCTAssertFalse(app.navigationBars["Library"].exists)
    }
}
