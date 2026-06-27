import XCTest
@testable import DrivePulseApp

import Foundation
import DrivePulseCore

final class Task6SettingsAndActionsTests: XCTestCase {
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
            sessionMetrics: .empty(historyLimit: 0),
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: [MountedVolume(bsdName: "disk42s2")]
        )

        let ejectAction = try XCTUnwrap(
            SystemAction.actions(for: device).first(where: { $0.kind == .eject })
        )

        XCTAssertEqual(ejectAction.intent, .ejectPhysicalDevice(bsdName: "disk42"))
    }

    func testRevealActionUsesNativeVolumeLookup() throws {
        let diskArbitration = StubDiskArbitrationClient(volumeURLs: [
            "disk42s1": URL(fileURLWithPath: "/Volumes/Field")
        ])
        let workspace = StubWorkspaceClient()
        let actions = SystemActions(
            diskArbitration: diskArbitration,
            workspace: workspace,
            commandRunner: StubCommandRunner()
        )

        try actions.perform(
            SystemAction(kind: .openInFinder, intent: .revealInFinder(volumeBSDName: "disk42s1"))
        )

        XCTAssertEqual(diskArbitration.lookedUpVolumeBSDNames, ["disk42s1"])
        XCTAssertEqual(workspace.revealedURLs, [URL(fileURLWithPath: "/Volumes/Field")])
    }

    func testEjectActionUsesNativeDiskArbitrationSequence() throws {
        let diskArbitration = StubDiskArbitrationClient()
        let actions = SystemActions(
            diskArbitration: diskArbitration,
            workspace: StubWorkspaceClient(),
            commandRunner: StubCommandRunner()
        )

        try actions.perform(
            SystemAction(kind: .eject, intent: .ejectPhysicalDevice(bsdName: "disk42"))
        )

        XCTAssertEqual(diskArbitration.ejectedWholeDiskBSDNames, ["disk42"])
    }
}

private final class StubDiskArbitrationClient: DiskArbitrationClient {
    var volumeURLs: [String: URL] = [:]
    private(set) var lookedUpVolumeBSDNames: [String] = []
    private(set) var ejectedWholeDiskBSDNames: [String] = []

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

    func ejectWholeDisk(bsdName: String) throws {
        ejectedWholeDiskBSDNames.append(bsdName)
    }
}

private final class StubWorkspaceClient: WorkspaceClient {
    private(set) var revealedURLs: [URL] = []

    func reveal(_ urls: [URL]) {
        revealedURLs = urls
    }

    func openApplication(at url: URL) {
        _ = url
    }
}

private struct StubCommandRunner: CommandRunner {
    func run(_ executablePath: String, arguments: [String]) throws -> Data {
        _ = executablePath
        _ = arguments
        return Data()
    }
}
