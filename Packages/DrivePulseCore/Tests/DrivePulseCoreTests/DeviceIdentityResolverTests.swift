import XCTest
@testable import DrivePulseCore

final class DeviceIdentityResolverTests: XCTestCase {
    func testIdentityEvidenceUsesPersistentMediaUUIDFirst() {
        let evidence = DeviceIdentityEvidence(
            mediaUUID: "  ABCD-1234  ",
            registryEntryID: 42,
            sessionID: "session"
        )

        XCTAssertEqual(
            evidence.deviceID(for: "disk9"),
            DeviceID(rawValue: "session:session:media:abcd-1234")
        )
    }

    func testRegistryEntryIDProducesSessionScopedIdentity() {
        let evidence = DeviceIdentityEvidence(registryEntryID: 42)

        XCTAssertEqual(
            evidence.deviceID(for: "disk9"),
            DeviceID(
                rawValue: "session:\(DeviceIdentityResolver.processSessionID):registry:2a"
            )
        )
    }

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

    func testResolverAcceptsExplicitExternalFlagRegardlessOfTransportPath() {
        // Thunderbolt 3 PCIe-tunneled NVMe enclosures report Protocol=PCI-Express,
        // which doesn't match usb/thunderbolt/usb4. DA still marks them external.
        let descriptor = ExternalDeviceDescriptor(
            deviceInternal: false,
            transportPath: ["PCI-Express", "IONVMeController", "AppleT6000PCIeC"],
            isNetworkVolume: false,
            isWholeMedia: true
        )

        XCTAssertTrue(DeviceIdentityResolver.isExternalPhysicalDevice(descriptor))
    }

    func testResolverRejectsExplicitInternalWithPCIeTransport() {
        let descriptor = ExternalDeviceDescriptor(
            deviceInternal: true,
            transportPath: ["PCI-Express", "AppleNVMeController"],
            isNetworkVolume: false,
            isWholeMedia: true
        )

        XCTAssertFalse(DeviceIdentityResolver.isExternalPhysicalDevice(descriptor))
    }
}
