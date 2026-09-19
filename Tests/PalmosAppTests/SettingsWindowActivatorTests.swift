import AppKit
import XCTest
@testable import PalmosApp
import PalmosCore

@MainActor
final class SettingsWindowActivatorTests: XCTestCase {
    func testOpenCreatesAndReusesOneSettingsWindowController() {
        let application = TestSettingsApplication()
        var controllers: [TestSettingsWindowPresenter] = []
        let activator = SettingsWindowActivator(application: application) {
            let controller = TestSettingsWindowPresenter()
            controllers.append(controller)
            return controller
        }

        activator.open()
        activator.open()

        XCTAssertEqual(controllers.count, 1)
        XCTAssertEqual(controllers[0].presentCount, 2)
        XCTAssertEqual(application.activationPolicies, [.regular, .regular])
        XCTAssertEqual(application.activationCount, 2)
    }

    func testClosingSettingsWindowRestoresAccessoryPolicy() throws {
        let application = TestSettingsApplication()
        let presenter = TestSettingsWindowPresenter()
        let activator = SettingsWindowActivator(application: application) { presenter }

        activator.open()
        try XCTUnwrap(presenter.onClose)()

        XCTAssertEqual(application.activationPolicies, [.regular, .accessory])
    }

    func testSettingsWindowMatchesAlcovePreferenceWindowStructure() {
        let controller = makeWindowController()
        let window = controller.window

        XCTAssertEqual(
            window?.contentView?.bounds.size,
            NSSize(
                width: SettingsWindowController.contentWidth,
                height: SettingsWindowController.minimumContentHeight
            )
        )
        XCTAssertEqual(window?.styleMask, [.titled, .closable])
        XCTAssertEqual(window?.title, "")
        XCTAssertEqual(window?.titleVisibility, .visible)
        XCTAssertTrue(window?.titlebarAppearsTransparent == true)
        XCTAssertEqual(window?.toolbarStyle, .preference)
        XCTAssertEqual(window?.toolbar?.displayMode, .iconAndLabel)
        XCTAssertEqual(window?.titlebarSeparatorStyle, NSTitlebarSeparatorStyle.none)
        XCTAssertTrue(window?.standardWindowButton(.miniaturizeButton)?.isHidden == true)
        XCTAssertTrue(window?.standardWindowButton(.zoomButton)?.isHidden == true)
        XCTAssertTrue(window?.standardWindowButton(.closeButton)?.isHidden == false)
        XCTAssertEqual(Set(controller.categoryItems.keys), Set(SettingsCategory.allCases))
        XCTAssertTrue(controller.categoryItems.values.allSatisfy { $0.isBordered == false })
    }

    func testSelectingCategoryUpdatesToolbarAndHostedPane() {
        let controller = makeWindowController()

        controller.selectCategory(.display)

        XCTAssertEqual(controller.selectedCategory, .display)
        XCTAssertEqual(
            controller.window?.toolbar?.selectedItemIdentifier,
            SettingsCategory.display.toolbarItemIdentifier
        )
    }

    func testWindowHeightUsesMinimumAndExpandsForTallerContent() {
        XCTAssertEqual(
            SettingsWindowController.resolvedContentHeight(for: 320),
            SettingsWindowController.minimumContentHeight
        )
        XCTAssertEqual(SettingsWindowController.resolvedContentHeight(for: 612), 612)
    }

    func testRelaunchWaitsForTerminationAndStartsOneActivatedInstance() {
        let applicationURL = URL(fileURLWithPath: "/Applications/Palmos.app", isDirectory: true)
        var launchedURL: URL?
        var launchesNewInstance = false
        var activates = false
        var terminateCount = 0
        let notificationCenter = NotificationCenter()
        let controller = ApplicationRelaunchController(
            applicationURL: applicationURL,
            notificationCenter: notificationCenter,
            launchHandler: { url, configuration in
                launchedURL = url
                launchesNewInstance = configuration.createsNewApplicationInstance
                activates = configuration.activates
            }
        )

        controller.requestRelaunch { terminateCount += 1 }

        XCTAssertEqual(terminateCount, 1)
        XCTAssertNil(launchedURL)

        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(launchedURL, applicationURL)
        XCTAssertTrue(launchesNewInstance)
        XCTAssertTrue(activates)

        launchedURL = nil
        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertNil(launchedURL)
    }

    func testOrdinaryTerminationDoesNotRelaunch() {
        let notificationCenter = NotificationCenter()
        var launchCount = 0
        let controller = ApplicationRelaunchController(
            notificationCenter: notificationCenter,
            launchHandler: { _, _ in launchCount += 1 }
        )

        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(launchCount, 0)
        withExtendedLifetime(controller) {}
    }

    private func makeWindowController() -> SettingsWindowController {
        SettingsWindowController(
            settings: AppSettings(),
            launchAtLoginController: LaunchAtLoginController(),
            smartHelperManager: SMARTHelperManager(
                inspector: TestSMARTHelperInspector(),
                installer: TestHelperInstaller()
            ),
            onInstallOrUpdateHelper: {},
            onRefreshHelperStatus: {},
            onRequestRelaunch: {},
            canCheckForUpdates: { false },
            onCheckForUpdates: {}
        )
    }
}

@MainActor
private final class TestSettingsApplication: SettingsApplicationProviding {
    private(set) var activationPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCount = 0

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        activationPolicies.append(policy)
    }

    func activate() {
        activationCount += 1
    }
}

@MainActor
private final class TestSettingsWindowPresenter: SettingsWindowPresenting {
    var onClose: (() -> Void)?
    private(set) var presentCount = 0

    func present() {
        presentCount += 1
    }
}

private struct TestSMARTHelperInspector: SMARTHelperInspecting {
    func inspectSMARTHelper() async -> SMARTHelperInspection {
        .notInstalled
    }
}

private struct TestHelperInstaller: HelperInstalling {
    func install() async throws {}
}
