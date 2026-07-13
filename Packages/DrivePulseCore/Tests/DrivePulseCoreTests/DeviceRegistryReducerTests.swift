import XCTest
@testable import DrivePulseCore

final class DeviceRegistryReducerTests: XCTestCase {
    func testReducerGroupsVolumesUnderPhysicalRoot() {
        let reducer = DeviceRegistryReducer()

        let snapshot = reducer.reduce(
            physicalBSDName: "disk4",
            containerBSDName: "disk5",
            volumes: [
                MountedVolume(bsdName: "disk5s1"),
                MountedVolume(bsdName: "disk5s2")
            ]
        )

        XCTAssertEqual(
            snapshot,
            ExternalDevice(
                physicalStoreBSDName: "disk4",
                apfsContainerBSDName: "disk5",
                volumes: [
                    MountedVolume(bsdName: "disk5s1"),
                    MountedVolume(bsdName: "disk5s2")
                ]
            )
        )
    }
}
