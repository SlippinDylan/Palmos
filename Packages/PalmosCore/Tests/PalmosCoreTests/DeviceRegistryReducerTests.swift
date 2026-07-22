import XCTest
@testable import PalmosCore

final class DeviceRegistryReducerTests: XCTestCase {
    func testReducerGroupsVolumesUnderPhysicalRoot() {
        let reducer = DeviceRegistryReducer()

        let snapshot = reducer.reduce(
            physicalBSDName: "disk4",
            containerBSDName: "disk5",
            volumes: [
                MountedVolume(bsdName: "disk5s1"),
                MountedVolume(bsdName: "disk5s2")
            ],
            identityEvidence: DeviceIdentityEvidence(registryEntryID: 42)
        )

        XCTAssertEqual(
            snapshot.id,
            DeviceID(
                rawValue: "session:\(DeviceIdentityResolver.processSessionID):registry:2a"
            )
        )
        XCTAssertEqual(snapshot.physicalStoreBSDName, "disk4")
        XCTAssertEqual(snapshot.apfsContainerBSDName, "disk5")
        XCTAssertEqual(snapshot.volumes.count, 2)
    }

    func testIdentityEvidencePrefersMediaUUIDOverRegistryEntryID() {
        let device = DeviceRegistryReducer().reduce(
            physicalBSDName: "disk4",
            containerBSDName: nil,
            volumes: [],
            identityEvidence: DeviceIdentityEvidence(mediaUUID: " ABC-123 ", registryEntryID: 99)
        )

        XCTAssertEqual(device.id, DeviceID(rawValue: "media:abc-123"))
    }

    func testMissingEvidenceUsesExplicitSessionScopedID() {
        let device = DeviceRegistryReducer().reduce(
            physicalBSDName: "disk4",
            containerBSDName: nil,
            volumes: [],
            identityEvidence: DeviceIdentityEvidence(sessionID: "test-session")
        )

        XCTAssertEqual(device.id, DeviceID(rawValue: "session:test-session:disk4"))
        XCTAssertNotEqual(device.id, DeviceID(rawValue: "disk4"))
    }

    func testConvenienceInitializerUsesSessionScopedIdentity() {
        let device = ExternalDevice(
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: nil,
            volumes: []
        )
        let replacement = ExternalDevice(
            physicalStoreBSDName: "disk4",
            apfsContainerBSDName: nil,
            volumes: []
        )

        XCTAssertTrue(device.id.rawValue.hasPrefix("session:"))
        XCTAssertNotEqual(device.id, DeviceID(rawValue: "disk4"))
        XCTAssertNotEqual(device.id, replacement.id)
    }
}
