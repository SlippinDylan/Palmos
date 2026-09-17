import XCTest
@testable import PalmosApp

@MainActor
final class ApplicationUpdateControllerTests: XCTestCase {
    func testDisabledUpdaterCannotCheckForUpdates() {
        let controller = ApplicationUpdateController(updaterEnabled: false, updateChannel: "stable")

        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
    }

    func testStableBuildUsesOnlyTheDefaultChannel() {
        XCTAssertEqual(ApplicationUpdateController.allowedChannels(for: "stable"), [])
    }

    func testBetaBuildAlsoReceivesBetaUpdates() {
        XCTAssertEqual(ApplicationUpdateController.allowedChannels(for: "beta"), ["beta"])
    }

    func testAlphaBuildReceivesAlphaAndBetaUpdates() {
        XCTAssertEqual(ApplicationUpdateController.allowedChannels(for: "alpha"), ["alpha", "beta"])
    }
}
