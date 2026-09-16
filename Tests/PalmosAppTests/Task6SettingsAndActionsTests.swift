import XCTest
@testable import PalmosApp

import Foundation
import ServiceManagement
import PalmosCore

final class Task6SettingsAndActionsTests: XCTestCase {
    func testMenuBarIconReflectsConnectedExternalDevicePresence() {
        XCTAssertEqual(
            MenuBarIcon.systemImageName(hasConnectedDevices: false),
            "externaldrive"
        )
        XCTAssertEqual(
            MenuBarIcon.systemImageName(hasConnectedDevices: true),
            "externaldrive.fill"
        )
    }

    func testAboutMetadataFormatsBundleVersionAndBuild() {
        let metadata = AboutAppMetadata(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42"
        ])

        XCTAssertEqual(metadata.versionDescription, "1.2.3 (42)")
    }

    func testAboutMetadataDoesNotInventMissingVersionInformation() {
        XCTAssertEqual(
            AboutAppMetadata(infoDictionary: [:]).versionDescription,
            "—"
        )
        XCTAssertEqual(
            AboutAppMetadata(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3"
            ]).versionDescription,
            "1.2.3"
        )
    }

    @MainActor
    func testLaunchAtLoginRefreshStatusPicksUpExternalSystemChanges() {
        let service = StubLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertFalse(controller.isEnabled)

        service.status = .enabled
        controller.refreshStatus()

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
    }

    func testSettingsRoundTripTemperatureUnit() {
        let suiteName = "Task6SettingsAndActionsTests.\(#function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.temperatureUnit, .celsius)

        settings.temperatureUnit = .fahrenheit

        let restoredSettings = AppSettings(defaults: defaults)
        XCTAssertEqual(restoredSettings.temperatureUnit, .fahrenheit)
    }

    func testEjectActionTargetsPhysicalDeviceIdentifier() throws {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "selected-device"),
            displayName: "Sample Drive",
            transportName: "USB-C",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(),
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: [MountedVolume(bsdName: "disk42s2")]
        )

        let ejectAction = try XCTUnwrap(
            SystemAction.footerActions(for: device).first(where: { $0.kind == .eject })
        )

        XCTAssertEqual(ejectAction.intent, .ejectPhysicalDevice(bsdName: "disk42"))
    }

    func testFooterActionsKeepQuitLast() {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "selected-device"),
            displayName: "Sample Drive",
            transportName: "USB-C",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(),
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: [MountedVolume(bsdName: "disk42s2")]
        )

        let actions = SystemAction.footerActions(for: device)

        XCTAssertEqual(actions.last?.kind, .quit)
    }

    func testFooterActionsWithoutDeviceShowOnlyDiskUtilityAndQuit() {
        XCTAssertEqual(
            SystemAction.footerActions(for: nil).map(\.kind),
            [.openDiskUtility, .quit]
        )
    }

    func testUnmountedDeviceStillOffersEject() {
        let unmountedDevice = ExternalDevice(
            id: DeviceID(rawValue: "selected-device"),
            displayName: "Sample Drive",
            transportName: "USB-C",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(),
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: []
        )

        XCTAssertEqual(
            SystemAction.footerActions(for: unmountedDevice).map(\.kind),
            [.eject, .openDiskUtility, .quit]
        )
    }

    func testFinderAndDiskUtilityActionsDismissMenuBarPanelButEjectAndQuitDoNot() {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "selected-device"),
            displayName: "Sample Drive",
            transportName: "USB-C",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(),
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: [MountedVolume(bsdName: "disk42s2")]
        )

        let dismissalByKind = Dictionary(
            uniqueKeysWithValues: SystemAction.footerActions(for: device)
                .map { ($0.kind, $0.dismissesMenuBarPanelOnDispatch) }
        )

        XCTAssertEqual(dismissalByKind[.openInFinder], true)
        XCTAssertEqual(dismissalByKind[.openDiskUtility], true)
        XCTAssertEqual(dismissalByKind[.eject], false)
        XCTAssertEqual(dismissalByKind[.quit], false)
    }

    func testFooterActionsUseCompactTitles() {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "selected-device"),
            displayName: "Sample Drive",
            transportName: "USB-C",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(),
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: [MountedVolume(bsdName: "disk42s2")]
        )

        let actions = SystemAction.footerActions(for: device)
        let titles = actions.map(\.footerTitle)

        XCTAssertEqual(
            titles,
            [
                String(localized: "Finder"),
                String(localized: "Eject"),
                String(localized: "Disk Utility"),
                String(localized: "Quit")
            ]
        )
        XCTAssertNotEqual(actions[0].footerTitle, actions[0].title)
        XCTAssertNotEqual(actions[1].footerTitle, actions[1].title)
    }

    func testMenuBarVisualStyleUsesLiquidGlassOnlyOnMacOS26AndNewer() {
        XCTAssertFalse(
            MenuBarVisualStyle.supportsLiquidGlass(
                OperatingSystemVersion(majorVersion: 25, minorVersion: 6, patchVersion: 0)
            )
        )
        XCTAssertTrue(
            MenuBarVisualStyle.supportsLiquidGlass(
                OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
            )
        )
    }

    func testDeviceFooterLayoutUsesStableStackedCapsules() {
        let metrics = FooterActionLayoutMetrics.forMode(.device)

        XCTAssertEqual(metrics.labelLayout, .stacked)
        XCTAssertEqual(metrics.controlSpacing, 6)
        XCTAssertEqual(metrics.horizontalPadding, 8)
        XCTAssertEqual(metrics.verticalPadding, 8)
        XCTAssertEqual(metrics.titleFontSize, 10)
        XCTAssertEqual(metrics.minHeight, 46)
        XCTAssertNil(metrics.fixedWidth)
    }

    func testEmptyFooterLayoutUsesCenteredHorizontalCapsules() {
        let metrics = FooterActionLayoutMetrics.forMode(.empty)

        XCTAssertEqual(metrics.labelLayout, .horizontal)
        XCTAssertEqual(metrics.minHeight, 34)
        XCTAssertEqual(metrics.fixedWidth, 132)
    }

    func testPanelContentHeightNeverExceedsVisibleScreenAfterFixedShell() {
        let availableHeight: CGFloat = 768
        let contentHeight = MenuBarPanelLayout.contentAreaHeight(
            availableHeight: availableHeight
        )

        XCTAssertEqual(contentHeight, 561)
        XCTAssertLessThanOrEqual(
            contentHeight + MenuBarPanelLayout.fixedShellHeight,
            MenuBarPanelLayout.usablePanelHeight(availableHeight: availableHeight)
        )
        let recoverySupplement = MenuBarPanelLayout.footerSupplementHeight(
            availableHeight: availableHeight,
            showsFeedback: true,
            showsRecovery: true
        )
        let recoveryContentHeight = MenuBarPanelLayout.contentAreaHeight(
            availableHeight: availableHeight,
            showsFeedback: true,
            showsRecovery: true
        )
        XCTAssertLessThanOrEqual(
            recoveryContentHeight
                + MenuBarPanelLayout.fixedShellHeight
                + recoverySupplement,
            MenuBarPanelLayout.usablePanelHeight(availableHeight: availableHeight)
        )
        XCTAssertGreaterThanOrEqual(
            recoveryContentHeight,
            MenuBarPanelLayout.minimumFixedContentHeight
        )
        XCTAssertEqual(
            MenuBarPanelLayout.recoveryViewMaximumHeight(
                availableHeight: availableHeight,
                showsFeedback: false
            ),
            98
        )
        XCTAssertEqual(
            MenuBarPanelLayout.recoveryViewMaximumHeight(
                availableHeight: 720,
                showsFeedback: false
            ),
            50
        )
    }

    func testPanelExpandsToUseTallScreenInsteadOfApplyingFixedHeightCap() {
        let availableHeight: CGFloat = 1_440
        let usableHeight = MenuBarPanelLayout.usablePanelHeight(
            availableHeight: availableHeight
        )
        let contentHeight = MenuBarPanelLayout.contentAreaHeight(
            availableHeight: availableHeight
        )

        XCTAssertEqual(usableHeight, 1_428)
        XCTAssertEqual(contentHeight, 1_233)
        XCTAssertEqual(
            contentHeight + MenuBarPanelLayout.fixedShellHeight,
            usableHeight
        )
        XCTAssertGreaterThan(contentHeight, 680)
    }

    func testPanelUsesNaturalDetailsHeightUntilScreenCapacityIsReached() {
        let maximumContentHeight: CGFloat = 800
        let fixedDetailsHeight: CGFloat = 300

        XCTAssertEqual(
            MenuBarPanelLayout.detailsViewportHeight(
                maximumContentAreaHeight: maximumContentHeight,
                fixedDetailsHeight: fixedDetailsHeight,
                detailsContentHeight: 200
            ),
            200
        )
        XCTAssertEqual(
            MenuBarPanelLayout.resolvedContentAreaHeight(
                maximumContentAreaHeight: maximumContentHeight,
                fixedDetailsHeight: fixedDetailsHeight,
                detailsContentHeight: 200
            ),
            540
        )

        XCTAssertEqual(
            MenuBarPanelLayout.detailsViewportHeight(
                maximumContentAreaHeight: maximumContentHeight,
                fixedDetailsHeight: fixedDetailsHeight,
                detailsContentHeight: 1_000
            ),
            460
        )
        XCTAssertEqual(
            MenuBarPanelLayout.resolvedContentAreaHeight(
                maximumContentAreaHeight: maximumContentHeight,
                fixedDetailsHeight: fixedDetailsHeight,
                detailsContentHeight: 1_000
            ),
            maximumContentHeight
        )
        XCTAssertEqual(
            MenuBarPanelLayout.resolvedContentAreaHeight(
                maximumContentAreaHeight: maximumContentHeight,
                fixedDetailsHeight: fixedDetailsHeight,
                detailsContentHeight: 0
            ),
            328
        )
    }

    func testFinderActionOpensNativeVolumeURLWithoutRevealingIt() async throws {
        let diskArbitration = StubDiskArbitrationClient(volumeURLs: [
            "disk42s1": URL(fileURLWithPath: "/Volumes/Field")
        ])
        let workspace = StubWorkspaceClient()
        let actions = SystemActions(
            diskArbitration: diskArbitration,
            workspace: workspace
        )

        try await actions.perform(
            SystemAction(kind: .openInFinder, intent: .revealInFinder(volumeBSDName: "disk42s1"))
        )

        XCTAssertEqual(diskArbitration.lookedUpVolumeBSDNames, ["disk42s1"])
        XCTAssertEqual(workspace.openedURLs, [URL(fileURLWithPath: "/Volumes/Field")])
    }

    func testOpenDiskUtilityActionLaunchesDiskUtilityByBundleIdentifier() async throws {
        let workspace = StubWorkspaceClient()
        let actions = SystemActions(
            diskArbitration: StubDiskArbitrationClient(),
            workspace: workspace
        )

        try await actions.perform(
            SystemAction(kind: .openDiskUtility, intent: .openDiskUtility)
        )

        XCTAssertEqual(workspace.openedApplicationBundleIdentifiers, ["com.apple.DiskUtility"])
    }

}

private final class StubDiskArbitrationClient: DiskVolumeLocating, @unchecked Sendable {
    var volumeURLs: [String: URL] = [:]
    private(set) var lookedUpVolumeBSDNames: [String] = []

    init(volumeURLs: [String: URL] = [:]) {
        self.volumeURLs = volumeURLs
    }

    func volumeURL(for bsdName: String) throws -> URL {
        lookedUpVolumeBSDNames.append(bsdName)

        guard let url = volumeURLs[bsdName] else {
            throw NSError(domain: "StubDiskArbitrationClient", code: 1)
        }

        return url
    }
}

private final class StubWorkspaceClient: WorkspaceClient, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []
    private(set) var openedApplicationBundleIdentifiers: [String] = []

    @MainActor
    func open(_ url: URL) async throws {
        openedURLs.append(url)
    }

    @MainActor
    func openApplication(bundleIdentifier: String) async throws {
        openedApplicationBundleIdentifiers.append(bundleIdentifier)
    }
}

private final class StubLaunchAtLoginService: LaunchAtLoginServicing, @unchecked Sendable {
    var status: SMAppService.Status

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {}

    func unregister(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
}
