import XCTest
@testable import PalmosApp

import PalmosCore

@MainActor
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
                "File System"
            ]
        )
    }

    func testCapacityModelPrefersAPFSContainerValues() {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "disk4"),
            displayName: "External",
            transportName: "USB",
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: "disk4s2",
            volumes: [MountedVolume(
                bsdName: "disk4s1",
                mountPoint: "/Volumes/External",
                capacityTotalBytes: 100,
                capacityAvailableBytes: 40,
                capacityConsumedBytes: 60
            )],
            apfsContainerDetails: APFSContainerInfo(
                bsdName: "disk4s2",
                totalCapacityBytes: 1_000,
                capacityInUseBytes: 750,
                capacityNotAllocatedBytes: 250
            )
        )

        let model = CapacityUsageModel(device: device)

        XCTAssertEqual(model.totalBytes, 1_000)
        XCTAssertEqual(model.usedBytes, 750)
        XCTAssertEqual(model.availableBytes, 250)
        XCTAssertEqual(model.usedFraction, 0.75, accuracy: 0.000_1)
        XCTAssertEqual(model.availableFraction, 0.25, accuracy: 0.000_1)
    }

    func testCapacityModelFallsBackToMountedVolumeValues() {
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

        let model = CapacityUsageModel(device: device)

        XCTAssertEqual(model.totalBytes, 100)
        XCTAssertEqual(model.usedBytes, 60)
        XCTAssertEqual(model.availableBytes, 40)
        XCTAssertEqual(model.usedFraction, 0.6, accuracy: 0.000_1)
        XCTAssertEqual(model.availableFraction, 0.4, accuracy: 0.000_1)
    }

    func testCapacityModelDoesNotMixPartialContainerAndVolumeValues() {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "disk4"),
            displayName: "External",
            transportName: "USB",
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: "disk4s2",
            volumes: [
                MountedVolume(
                    bsdName: "disk4s1",
                    capacityTotalBytes: 100,
                    capacityAvailableBytes: nil,
                    capacityConsumedBytes: 60
                ),
                MountedVolume(
                    bsdName: "disk4s3",
                    capacityTotalBytes: 200,
                    capacityAvailableBytes: 80,
                    capacityConsumedBytes: 120
                )
            ],
            apfsContainerDetails: APFSContainerInfo(
                bsdName: "disk4s2",
                totalCapacityBytes: 1_000,
                capacityInUseBytes: nil,
                capacityNotAllocatedBytes: 250
            )
        )

        let model = CapacityUsageModel(device: device)

        XCTAssertEqual(model.totalBytes, 200)
        XCTAssertEqual(model.usedBytes, 120)
        XCTAssertEqual(model.availableBytes, 80)
    }

    func testCapacityModelUsesStableMissingState() {
        let model = CapacityUsageModel(device: ExternalDevice(
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: nil,
            volumes: [MountedVolume(bsdName: "disk4s1")]
        ))

        XCTAssertNil(model.totalBytes)
        XCTAssertNil(model.usedBytes)
        XCTAssertNil(model.availableBytes)
        XCTAssertEqual(model.usedFraction, 0)
        XCTAssertEqual(model.availableFraction, 0)
    }

    func testCapacityModelNormalizesInconsistentSegmentTotals() {
        let model = CapacityUsageModel(device: ExternalDevice(
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: nil,
            volumes: [MountedVolume(
                bsdName: "disk4s1",
                capacityTotalBytes: 100,
                capacityAvailableBytes: 60,
                capacityConsumedBytes: 80
            )]
        ))

        XCTAssertEqual(model.usedFraction, 80.0 / 140.0, accuracy: 0.000_1)
        XCTAssertEqual(model.availableFraction, 60.0 / 140.0, accuracy: 0.000_1)
        XCTAssertEqual(model.usedFraction + model.availableFraction, 1, accuracy: 0.000_1)
    }
}
