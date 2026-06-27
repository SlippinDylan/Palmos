import XCTest
@testable import DrivePulseCore

final class DeviceIdentityResolverTests: XCTestCase {
    func testResolverRejectsInternalAppleSiliconStore() {
        let descriptor = ExternalDeviceDescriptor(
            deviceInternal: true,
            transportPath: ["AppleANS3CGv2Controller"],
            isNetworkVolume: false,
            isWholeMedia: true
        )

        XCTAssertFalse(DeviceIdentityResolver.isExternalPhysicalDevice(descriptor))
    }

    func testResolverRejectsNonWholeMedia() {
        let descriptor = ExternalDeviceDescriptor(
            deviceInternal: false,
            transportPath: ["USB Mass Storage"],
            isNetworkVolume: false,
            isWholeMedia: false
        )

        XCTAssertFalse(DeviceIdentityResolver.isExternalPhysicalDevice(descriptor))
    }

    func testResolverRejectsNetworkVolume() {
        let descriptor = ExternalDeviceDescriptor(
            deviceInternal: false,
            transportPath: ["Thunderbolt Bus"],
            isNetworkVolume: true,
            isWholeMedia: true
        )

        XCTAssertFalse(DeviceIdentityResolver.isExternalPhysicalDevice(descriptor))
    }

    func testResolverAcceptsSupportedExternalTransportPaths() {
        let transportPaths = [
            "USB Mass Storage",
            "Thunderbolt Port",
            "USB4 Root Hub",
            "SD Card Reader"
        ]

        for transportPath in transportPaths {
            let descriptor = ExternalDeviceDescriptor(
                deviceInternal: false,
                transportPath: [transportPath],
                isNetworkVolume: false,
                isWholeMedia: true
            )

            XCTAssertTrue(
                DeviceIdentityResolver.isExternalPhysicalDevice(descriptor),
                "Expected transport path \(transportPath) to be treated as external"
            )
        }
    }

    func testResolverDoesNotTreatAppleSSDControllerAsSDTransport() {
        let descriptor = ExternalDeviceDescriptor(
            deviceInternal: nil,
            transportPath: ["Apple SSD Controller"],
            isNetworkVolume: false,
            isWholeMedia: true
        )

        XCTAssertFalse(DeviceIdentityResolver.isExternalPhysicalDevice(descriptor))
    }

    func testResolverRejectsUnsupportedTransportWithoutExternalSignal() {
        let descriptor = ExternalDeviceDescriptor(
            deviceInternal: nil,
            transportPath: ["PCI Storage Controller"],
            isNetworkVolume: false,
            isWholeMedia: true
        )

        XCTAssertFalse(DeviceIdentityResolver.isExternalPhysicalDevice(descriptor))
    }
}
