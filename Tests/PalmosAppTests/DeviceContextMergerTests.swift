import XCTest
@testable import PalmosApp

import PalmosCore

final class DeviceContextMergerTests: XCTestCase {
    func testMergePreservesRicherContextAndMountedVolumesForActiveEjectTarget() {
        let deviceID = DeviceID(rawValue: "disk42")
        let existing = ExternalDevice(
            id: deviceID,
            displayName: "Acme Portable SSD",
            transportName: "Thunderbolt",
            capacityBytes: 2_000,
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: [MountedVolume(bsdName: "disk42s1", mountPoint: "/Volumes/Acme")],
            nvmeInfo: NVMeInfo(model: "Acme NVMe", serialNumber: "serial-42")
        )
        let incoming = ExternalDevice(
            id: deviceID,
            displayName: "disk42",
            transportName: "External",
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: nil,
            volumes: []
        )

        let merged = DeviceContextMerger().merge(
            incoming: [incoming],
            existing: [existing],
            preservingMountedVolumesFor: deviceID
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].displayName, existing.displayName)
        XCTAssertEqual(merged[0].transportName, existing.transportName)
        XCTAssertEqual(merged[0].capacityBytes, existing.capacityBytes)
        XCTAssertEqual(merged[0].apfsContainerBSDName, existing.apfsContainerBSDName)
        XCTAssertEqual(merged[0].volumes, existing.volumes)
        XCTAssertEqual(merged[0].nvmeInfo, existing.nvmeInfo)
    }

    func testMergeDoesNotResurrectVolumesWithoutAnActiveEjectTarget() {
        let deviceID = DeviceID(rawValue: "disk42")
        let existing = ExternalDevice(
            id: deviceID,
            displayName: "Acme Portable SSD",
            transportName: "USB",
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: "disk42s2",
            volumes: [MountedVolume(bsdName: "disk42s1")]
        )
        let incoming = ExternalDevice(
            id: deviceID,
            displayName: "disk42",
            transportName: "External",
            physicalStoreBSDName: "disk42",
            apfsContainerBSDName: nil,
            volumes: []
        )

        let merged = DeviceContextMerger().merge(
            incoming: [incoming],
            existing: [existing],
            preservingMountedVolumesFor: nil
        )

        XCTAssertEqual(merged[0].volumes, [])
    }
}
