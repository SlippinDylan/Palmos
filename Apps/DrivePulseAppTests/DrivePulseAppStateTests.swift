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
