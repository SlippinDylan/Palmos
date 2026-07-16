import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class DrivePulseAppStateTests: XCTestCase {
    func testSelectionIgnoresUnmountedDevices() {
        let unmountedDevice = ExternalDevice(
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: "disk4s2",
            volumes: []
        )
        let mountedDevice = ExternalDevice.preview(id: "disk8")
        let state = DrivePulseAppState(
            devices: [unmountedDevice, mountedDevice],
            selectedDeviceID: unmountedDevice.id
        )

        XCTAssertEqual(state.devices.map(\.id), [unmountedDevice.id, mountedDevice.id])
        XCTAssertEqual(state.mountedDevices.map(\.id), [mountedDevice.id])
        XCTAssertEqual(state.selectedDeviceID, mountedDevice.id)
        XCTAssertEqual(state.selectedDevice?.id, mountedDevice.id)
    }

    func testMarkDeviceUnmountedSelectsNextMountedDevice() {
        let firstDevice = ExternalDevice.preview(id: "disk4")
        let secondDevice = ExternalDevice.preview(id: "disk8")
        var state = DrivePulseAppState(
            devices: [firstDevice, secondDevice],
            selectedDeviceID: firstDevice.id
        )

        state.markDeviceUnmounted(firstDevice.id)

        XCTAssertTrue(state.device(id: firstDevice.id)?.volumes.isEmpty == true)
        XCTAssertEqual(state.selectedDeviceID, secondDevice.id)
        XCTAssertEqual(state.selectedDevice?.id, secondDevice.id)
    }

    func testMarkOnlyDeviceUnmountedClearsPresentationSelection() {
        let device = ExternalDevice.preview(id: "disk4")
        var state = DrivePulseAppState(devices: [device], selectedDeviceID: device.id)

        state.markDeviceUnmounted(device.id)

        XCTAssertEqual(state.devices.map(\.id), [device.id])
        XCTAssertTrue(state.mountedDevices.isEmpty)
        XCTAssertNil(state.selectedDeviceID)
        XCTAssertNil(state.selectedDevice)
    }

    func testAppStateDefaultsToFirstDeviceWhenSelectionMissing() {
        let devices = [
            ExternalDevice.preview(id: "disk4"),
            ExternalDevice.preview(id: "disk8")
        ]
        let state = DrivePulseAppState(devices: devices, selectedDeviceID: nil)

        XCTAssertEqual(state.selectedDeviceID?.rawValue, "disk4")
        XCTAssertEqual(state.selectedDevice?.id.rawValue, "disk4")
        XCTAssertEqual(state.selectedDevice?.id, state.selectedDeviceID)
    }

    func testReplaceDevicesPreservesSelectionWhenDeviceStillExists() {
        var state = DrivePulseAppState(
            devices: [
                ExternalDevice.preview(id: "disk4"),
                ExternalDevice.preview(id: "disk8")
            ],
            selectedDeviceID: DeviceID(rawValue: "disk8")
        )

        state.replaceDevices([
            ExternalDevice.preview(id: "disk10"),
            ExternalDevice.preview(id: "disk8")
        ])

        XCTAssertEqual(state.selectedDeviceID?.rawValue, "disk8")
        XCTAssertEqual(state.selectedDevice?.id.rawValue, "disk8")
    }

    func testReplaceDevicesFallsBackToFirstDeviceWhenSelectionDisappears() {
        var state = DrivePulseAppState(
            devices: [
                ExternalDevice.preview(id: "disk4"),
                ExternalDevice.preview(id: "disk8")
            ],
            selectedDeviceID: DeviceID(rawValue: "disk8")
        )

        state.replaceDevices([
            ExternalDevice.preview(id: "disk12"),
            ExternalDevice.preview(id: "disk16")
        ])

        XCTAssertEqual(state.selectedDeviceID?.rawValue, "disk12")
        XCTAssertEqual(state.selectedDevice?.id.rawValue, "disk12")
    }

    func testReplaceDevicesPreservesSessionMetricsWhenRediscoveringSameDeviceID() {
        let preservedMetrics = DeviceSessionMetrics(
            currentReadBytesPerSecond: 512,
            currentWriteBytesPerSecond: 256,
            cumulativeReadBytes: 4_096,
            cumulativeWriteBytes: 2_048,
            readHistory: [
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 5_000), bytesPerSecond: 128),
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 5_060), bytesPerSecond: 512)
            ],
            writeHistory: [
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 5_000), bytesPerSecond: 64),
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 5_060), bytesPerSecond: 256)
            ]
        )
        var state = DrivePulseAppState(
            devices: [
                ExternalDevice(
                    id: DeviceID(rawValue: "disk8"),
                    displayName: "Original Device",
                    transportName: "USB-C",
                    capacityBytes: 1_000,
                    smartSnapshot: .notRequested,
                    sessionMetrics: preservedMetrics,
                    physicalStoreBSDName: "disk8",
                    apfsContainerBSDName: "disk8s2",
                    volumes: [MountedVolume(bsdName: "disk8s2")]
                )
            ],
            selectedDeviceID: DeviceID(rawValue: "disk8")
        )

        state.replaceDevices([
            ExternalDevice(
                id: DeviceID(rawValue: "disk8"),
                displayName: "Rediscovered Device",
                transportName: "USB 3.2",
                capacityBytes: 2_000,
                smartSnapshot: .notRequested,
                sessionMetrics: .empty(historyLimit: 0),
                physicalStoreBSDName: "disk8",
                apfsContainerBSDName: "disk8s3",
                volumes: [MountedVolume(bsdName: "disk8s3")]
            )
        ])

        XCTAssertEqual(state.selectedDeviceID?.rawValue, "disk8")
        XCTAssertEqual(state.selectedDevice?.displayName, "Rediscovered Device")
        XCTAssertEqual(state.selectedDevice?.transportName, "USB 3.2")
        XCTAssertEqual(state.selectedDevice?.sessionMetrics, preservedMetrics)
    }

    func testAppStateNormalizesInvalidSelectedDeviceIDOnInit() {
        let state = DrivePulseAppState(
            devices: [
                ExternalDevice.preview(id: "disk4"),
                ExternalDevice.preview(id: "disk8")
            ],
            selectedDeviceID: DeviceID(rawValue: "disk99")
        )

        XCTAssertEqual(state.selectedDeviceID?.rawValue, "disk4")
        XCTAssertEqual(state.selectedDevice?.id.rawValue, "disk4")
    }
}
