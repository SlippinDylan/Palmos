import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class OverviewCardViewTests: XCTestCase {
    func testRowsExcludeSmartWearAndTemperatureFields() {
        let rows = OverviewCardView.rows(
            for: ExternalDevice.preview(id: "disk4"),
            smartDetails: nil,
            settings: AppSettings()
        )

        XCTAssertEqual(
            rows.map(\.label),
            [
                "Model",
                "Connection",
                "Total Capacity",
                "Used",
                "Available",
                "File System",
                "Mounted"
            ]
        )
    }

    func testRowsUseMountedVolumeCapacityWithoutAPFSEnrichment() throws {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "disk4"),
            displayName: "External",
            transportName: "USB",
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: nil,
            volumes: [MountedVolume(
                bsdName: "disk4s1",
                mountPoint: "/Volumes/External",
                capacityTotalBytes: 100,
                capacityAvailableBytes: 40,
                capacityConsumedBytes: 60
            )]
        )

        let rows = OverviewCardView.rows(
            for: device,
            smartDetails: nil,
            settings: AppSettings()
        )

        XCTAssertNotEqual(try XCTUnwrap(rows.first { $0.label == "Used" }).value, "—")
        XCTAssertNotEqual(try XCTUnwrap(rows.first { $0.label == "Available" }).value, "—")
    }
}
