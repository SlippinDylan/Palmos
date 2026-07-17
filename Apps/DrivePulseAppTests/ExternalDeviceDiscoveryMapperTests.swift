import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class ExternalDeviceDiscoveryMapperTests: XCTestCase {
    func testMapGroupsMountedVolumesUnderExternalPhysicalDevice() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk21",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "field-ssd",
                mediaName: "Field SSD",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 2_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk21s1",
                parentBSDName: "disk21",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: false,
                volumePath: URL(fileURLWithPath: "/Volumes/Field SSD"),
                mediaName: "Field SSD",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 1_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk99",
                parentBSDName: nil,
                deviceInternal: nil,
                isNetworkVolume: true,
                isWholeMedia: true,
                volumePath: URL(fileURLWithPath: "/Volumes/Network"),
                mediaName: "Network Share",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "SMB",
                deviceProtocol: "SMB",
                capacityBytes: nil,
                mediaContent: nil,
                ioClassPath: ["IONetworkInterface"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].id.rawValue.hasSuffix(":media:field-ssd"))
        XCTAssertEqual(devices[0].displayName, "Acme Portable SSD")
        XCTAssertEqual(devices[0].transportName, "USB")
        XCTAssertEqual(
            devices[0].volumes,
            [MountedVolume(bsdName: "disk21s1", mountPoint: "/Volumes/Field SSD")]
        )
    }

    func testMapKeepsExternalDeviceVisibleWithoutMountedVolumes() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk84",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "archive",
                mediaName: "Archive",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "Thunderbolt",
                deviceProtocol: "Thunderbolt",
                capacityBytes: 4_000,
                mediaContent: nil,
                ioClassPath: ["AppleThunderboltPCIDownAdapter", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].id.rawValue.hasSuffix(":media:archive"))
        XCTAssertEqual(devices[0].transportName, "Thunderbolt")
        XCTAssertEqual(devices[0].volumes, [])
    }

    func testMapUsesDiskArbitrationWholeDiskRelationshipForMountedVolumes() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk21",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "capture",
                mediaName: "Capture",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 2_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk50",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "archive-usb",
                mediaName: "Archive",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 2_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk999s1",
                parentBSDName: "disk50",
                wholeDiskBSDName: "disk21",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: false,
                volumePath: URL(fileURLWithPath: "/Volumes/Capture"),
                mediaName: "Capture",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 1_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.first(where: { $0.physicalStoreBSDName == "disk21" })?.volumes, [
            MountedVolume(bsdName: "disk999s1", mountPoint: "/Volumes/Capture")
        ])
        XCTAssertEqual(
            devices.first(where: { $0.physicalStoreBSDName == "disk50" })?.volumes,
            [MountedVolume]()
        )
    }

    func testMapIncludesMountedWholeDiskRootAsVolume() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk3",
                parentBSDName: nil,
                wholeDiskBSDName: "disk3",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: URL(fileURLWithPath: "/Volumes/CAMERA_CARD"),
                mediaUUID: "camera-card",
                mediaName: "CAMERA_CARD",
                deviceModel: nil,
                deviceVendor: "Acme",
                busName: "SD",
                deviceProtocol: "SD",
                capacityBytes: 256_000,
                mediaContent: "DOS_FAT_32",
                ioClassPath: ["IOSDHostDevice", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].id.rawValue.hasSuffix(":media:camera-card"))
        XCTAssertEqual(devices[0].transportName, "SD")
        XCTAssertEqual(
            devices[0].volumes,
            [MountedVolume(bsdName: "disk3", mountPoint: "/Volumes/CAMERA_CARD")]
        )
    }

    func testMapCapturesAPFSContainerBSDName() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk7",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "backup",
                mediaName: "Backup",
                deviceModel: "Mini",
                deviceVendor: "Acme",
                busName: "USB4",
                deviceProtocol: "USB4",
                capacityBytes: 4_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk8",
                parentBSDName: "disk7",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaName: "Container",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "USB4",
                deviceProtocol: "USB4",
                capacityBytes: 4_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk8s1",
                parentBSDName: "disk8",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: false,
                volumePath: URL(fileURLWithPath: "/Volumes/Backup"),
                mediaName: "Backup",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "USB4",
                deviceProtocol: "USB4",
                capacityBytes: 2_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].apfsContainerBSDName, "disk8")
        XCTAssertEqual(
            devices[0].volumes,
            [MountedVolume(bsdName: "disk8s1", mountPoint: "/Volumes/Backup")]
        )
    }

    func testMapUsesMediaUUIDAcrossBSDNameReuse() {
        let mapper = ExternalDeviceDiscoveryMapper()
        let first = DiskDiscoveryRecord(
            bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaUUID: "same-media", mediaName: "Disk", deviceModel: nil,
            deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
            capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
        )
        let replacement = DiskDiscoveryRecord(
            bsdName: "disk8", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaUUID: "same-media", mediaName: "Disk", deviceModel: nil,
            deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
            capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
        )

        let firstID = mapper.map([first]).first?.id
        let replacementID = mapper.map([replacement]).first?.id
        XCTAssertEqual(firstID, replacementID)
        XCTAssertTrue(firstID?.rawValue.hasSuffix(":media:same-media") == true)
    }

    func testMapStartsNewSessionAfterMediaDisappears() {
        let mapper = ExternalDeviceDiscoveryMapper()
        let record = DiskDiscoveryRecord(
            bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaUUID: "same-media", mediaName: "Disk", deviceModel: nil,
            deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
            capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
        )

        let firstID = mapper.map([record]).first?.id
        XCTAssertTrue(mapper.map([]).isEmpty)
        let reinsertedID = mapper.map([record]).first?.id

        XCTAssertNotEqual(firstID, reinsertedID)
    }

    func testMapDoesNotUseBSDNameAsFallbackIdentity() {
        let mapper = ExternalDeviceDiscoveryMapper()
        let record = DiskDiscoveryRecord(
            bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaName: "Disk", deviceModel: nil, deviceVendor: nil,
            busName: "USB", deviceProtocol: "USB", capacityBytes: 1_000,
            mediaContent: nil, ioClassPath: []
        )

        let id = mapper.map([record]).first?.id
        XCTAssertNotEqual(id, DeviceID(rawValue: "disk4"))
        XCTAssertTrue(id?.rawValue.hasPrefix("session:") == true)
    }

    func testMapDisambiguatesDuplicateMediaUUIDEvidence() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
                isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
                mediaUUID: "duplicate", mediaName: "One", deviceModel: nil,
                deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
                capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
            ),
            DiskDiscoveryRecord(
                bsdName: "disk8", parentBSDName: nil, deviceInternal: false,
                isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
                mediaUUID: "duplicate", mediaName: "Two", deviceModel: nil,
                deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
                capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(Set(devices.map(\.id)).count, 2)
    }
}
