import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class DrivePulseAppStateTests: XCTestCase {
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
