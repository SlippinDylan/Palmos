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
}
