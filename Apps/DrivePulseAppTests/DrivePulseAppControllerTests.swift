import XCTest
@testable import DrivePulseApp

import DrivePulseCore

@MainActor
final class DrivePulseAppControllerTests: XCTestCase {
    func testControllerBootstrapsStateFromDiscovery() {
        let discoveredDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [discoveredDevices])

        let controller = DrivePulseAppController(deviceDiscovery: discovery)

        XCTAssertEqual(controller.state.devices, discoveredDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk21"))
        XCTAssertEqual(discovery.invocationCount, 1)
    }

    func testRefreshRequeriesDiscoveryAndReplacesDevices() {
        let initialDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let refreshedDevices = [
            makeDevice(id: "disk42", volumes: []),
            makeDevice(id: "disk84", volumes: ["disk84s2"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [initialDevices, refreshedDevices])
        let controller = DrivePulseAppController(deviceDiscovery: discovery)

        controller.refresh()

        XCTAssertEqual(controller.state.devices, refreshedDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk42"))
        XCTAssertEqual(discovery.invocationCount, 2)
    }

    func testControllerSubscribesToDiscoveryStreamAndAppliesUpdates() {
        let initialDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [initialDevices])
        let controller = DrivePulseAppController(deviceDiscovery: discovery)
        let updatedDevices = [
            makeDevice(id: "disk84", volumes: []),
            makeDevice(id: "disk126", volumes: ["disk126s1"])
        ]

        discovery.emit(updatedDevices)

        XCTAssertEqual(discovery.subscriptionCount, 1)
        XCTAssertEqual(controller.state.devices, updatedDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk84"))
    }

    private func makeDevice(id rawID: String, volumes: [String]) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: rawID),
            displayName: "Device \(rawID)",
            transportName: "USB",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(historyLimit: 0),
            physicalStoreBSDName: rawID,
            apfsContainerBSDName: nil,
            volumes: volumes.map(MountedVolume.init(bsdName:))
        )
    }
}

private final class StubExternalDeviceDiscovery: ExternalDeviceDiscovering {
    private let results: [[ExternalDevice]]
    private(set) var invocationCount = 0
    private(set) var subscriptionCount = 0
    private var onUpdate: (@MainActor @Sendable ([ExternalDevice]) -> Void)?

    init(results: [[ExternalDevice]]) {
        self.results = results
    }

    func discoverDevices() -> [ExternalDevice] {
        defer { invocationCount += 1 }

        let index = min(invocationCount, results.count - 1)
        return results[index]
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor @Sendable ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        subscriptionCount += 1
        self.onUpdate = onUpdate
        return StubExternalDeviceDiscoveryObservation()
    }

    @MainActor
    func emit(_ devices: [ExternalDevice]) {
        onUpdate?(devices)
    }
}

private struct StubExternalDeviceDiscoveryObservation: ExternalDeviceDiscoveryObservation {
    func cancel() {}
}
