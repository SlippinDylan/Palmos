import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class DeviceIdentityCardViewTests: XCTestCase {
    func testRowsPreserveExpectedFieldOrder() {
        let labels = DeviceIdentityCardView.rows(for: nil).map(\.label)

        XCTAssertEqual(
            labels,
            [
                "Physical Disk",
                "APFS Container",
                "APFS Volume",
                "Device Node",
                "Volume UUID",
                "Container UUID",
                "Physical Store UUID",
                "NVMe Serial",
                "Thunderbolt UID",
                "PCI Vendor ID",
                "PCI Device ID"
            ]
        )
    }

    func testRowsUseAPFSContainerVolumeWhenMountedVolumesAreUnavailable() {
        let device = ExternalDevice(
            id: DeviceID(rawValue: "disk4"),
            displayName: "Samsung-PM981a-1TB-NVMe",
            transportName: "Thunderbolt",
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: "disk5",
            volumes: [],
            apfsContainerDetails: APFSContainerInfo(
                bsdName: "disk5",
                physicalStoreBSDName: "disk4s2",
                containerUUID: "container-uuid",
                physicalStoreUUID: "store-uuid",
                volumes: [
                    APFSVolumeDetails(
                        volumeName: "Samsung-PM981a-1TB-NVMe",
                        bsdName: "disk5s1",
                        volumeUUID: "volume-uuid"
                    )
                ]
            )
        )

        let rows = DeviceIdentityCardView.rows(for: device)

        XCTAssertEqual(rows.first(where: { $0.label == "APFS Volume" })?.value, "disk5s1")
        XCTAssertEqual(rows.first(where: { $0.label == "Volume UUID" })?.value, "volume-uuid")
        XCTAssertEqual(rows.first(where: { $0.label == "Device Node" })?.value, "/dev/disk4")
    }
}
