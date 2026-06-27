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
        XCTAssertEqual(devices[0].id, DeviceID(rawValue: "disk21"))
        XCTAssertEqual(devices[0].displayName, "Acme Portable SSD")
        XCTAssertEqual(devices[0].transportName, "USB")
        XCTAssertEqual(devices[0].volumes, [MountedVolume(bsdName: "disk21s1")])
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
        XCTAssertEqual(devices[0].id, DeviceID(rawValue: "disk84"))
        XCTAssertEqual(devices[0].transportName, "Thunderbolt")
        XCTAssertEqual(devices[0].volumes, [])
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
        XCTAssertEqual(devices[0].volumes, [MountedVolume(bsdName: "disk8s1")])
    }
}
