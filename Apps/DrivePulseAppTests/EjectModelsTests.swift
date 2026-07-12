import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class EjectModelsTests: XCTestCase {
    func testTargetScopeMatchesFilesystemAncestryWithoutPrefixCollision() {
        let scope = OccupancyTargetScope(
            physicalBSDName: "disk4",
            deviceNodes: ["/dev/disk4", "/dev/rdisk4", "/dev/disk4s2"],
            mountURLs: [URL(fileURLWithPath: "/Volumes/Data")]
        )

        XCTAssertTrue(scope.contains(path: "/Volumes/Data/report.txt"))
        XCTAssertFalse(scope.contains(path: "/Volumes/Database/report.txt"))
        XCTAssertTrue(scope.contains(deviceNode: "/dev/disk4s2"))
        XCTAssertFalse(scope.contains(deviceNode: "/dev/disk40"))
    }

    func testWorkflowTargetCapturesStableIdentityAndTopologyGeneration() {
        let target = EjectWorkflowTarget(
            deviceID: DeviceID(rawValue: "serial:abc"),
            physicalBSDName: "disk4",
            mediaRegistryEntryID: 4_001,
            displayName: "Samsung T7",
            topologyGeneration: 9
        )

        XCTAssertEqual(target.physicalBSDName, "disk4")
        XCTAssertEqual(target.topologyGeneration, 9)
    }

    func testDomainTypesExposeThePlannedCasesAndValues() {
        let holder = OccupancyHolder(
            pid: 42,
            executableName: "backupd",
            displayName: "Backup Agent",
            type: .openFileOrDirectory
        )
        let target = EjectWorkflowTarget(
            deviceID: DeviceID(rawValue: "serial:abc"),
            physicalBSDName: "disk4",
            mediaRegistryEntryID: 4_001,
            displayName: "Samsung T7",
            topologyGeneration: 9
        )
        let failure = EjectFailure(
            stage: .unmounting,
            category: .busy,
            rawStatus: 16,
            systemMessage: "Resource busy",
            physicalBSDName: "disk4",
            holders: [holder]
        )
        let recovery = EjectRecoveryState(target: target, failure: failure, holders: [holder])

        XCTAssertEqual(holder.preferredName, "Backup Agent")
        XCTAssertEqual(OccupancyScanResult(holders: [holder], isComplete: true).holders, [holder])
        XCTAssertEqual(EjectWorkflowState.awaitingRecovery(recovery), .awaitingRecovery(recovery))
        XCTAssertEqual(EjectFailureCategory.notPermitted.rawValue, "notPermitted")
        XCTAssertEqual(EjectOperationStage.awaitingForceConfirmation.rawValue, "awaitingForceConfirmation")
        XCTAssertEqual(OccupancyType.allCases.count, 4)
    }
}
