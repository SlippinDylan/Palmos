import XCTest
@testable import DrivePulseCore

final class DeviceRegistryReducerTests: XCTestCase {
    func testReducerGroupsVolumesUnderPhysicalRoot() {
        let reducer = DeviceRegistryReducer()

        let snapshot = reducer.reduce(
            physicalBSDName: "disk4",
            containerBSDName: "disk5",
            volumeBSDNames: ["disk5s1", "disk5s2"]
        )

        XCTAssertEqual(snapshot.physicalStoreBSDName, "disk4")
        XCTAssertEqual(snapshot.apfsContainerBSDName, "disk5")
        XCTAssertEqual(snapshot.volumes.map(\.bsdName), ["disk5s1", "disk5s2"])
    }
}
