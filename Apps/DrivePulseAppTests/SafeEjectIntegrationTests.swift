@preconcurrency import DiskArbitration
import Foundation
import XCTest

import DrivePulseCore

@testable import DrivePulseApp

@MainActor
final class SafeEjectIntegrationTests: XCTestCase {
    func testFoundationBusyRecognizesAppHolderAndPersistsRecovery() async throws {
        let holder = OccupancyHolder(
            pid: 501,
            executableName: "Finder",
            displayName: "Finder",
            type: .openFileOrDirectory
        )
        let helper = IntegrationHelperScanner(result: .init(holders: [], isComplete: true))
        let scanner = OccupancyScanner(
            appScanner: IntegrationAppScanner(result: .init(holders: [holder], isComplete: true)),
            helperScanner: helper
        )
        let operations = IntegrationDAOperations(
            normalUnmount: .failure(status: DAReturn(kDAReturnBusy), message: "Volume is in use")
        )
        let fixture = makeCoordinator(
            ejecter: DiskArbitrationEjectClient(
                operations: operations
            ),
            scanner: scanner
        )

        fixture.coordinator.begin(deviceID: target.deviceID, displayName: target.displayName, topologyGeneration: 9)

        try await waitUntil { fixture.coordinator.state.recovery?.holders == [holder] }
        let helperCalls = await helper.callCount()
        XCTAssertEqual(helperCalls, 0)
        XCTAssertEqual(fixture.coordinator.state.recovery?.failure.category, .busy)
        await Task.yield()
        XCTAssertNotNil(fixture.coordinator.state.recovery)
    }

    func testEmptyIncompleteAppScanFallsBackToBoundedHelperOrHonestUnknown() async {
        let helperHolder = OccupancyHolder(
            pid: 88,
            executableName: "backupd",
            displayName: nil,
            type: .openFileOrDirectory
        )
        let known = OccupancyScanner(
            appScanner: IntegrationAppScanner(result: .init(holders: [], isComplete: false)),
            helperScanner: IntegrationHelperScanner(result: .init(holders: [helperHolder], isComplete: true))
        )
        let unknown = OccupancyScanner(
            appScanner: IntegrationAppScanner(result: .init(holders: [], isComplete: false)),
            helperScanner: FailingIntegrationHelperScanner()
        )

        let knownResult = await known.scan(workflowID: UUID(), scope: scope)
        let unknownResult = await unknown.scan(workflowID: UUID(), scope: scope)

        XCTAssertEqual(knownResult.holders, [helperHolder])
        XCTAssertTrue(knownResult.isComplete)
        XCTAssertEqual(unknownResult.holders, [])
        XCTAssertFalse(unknownResult.isComplete)
    }

    func testDrivePulseOwnedIOIsDrainedBeforeUnmountAndIsNotReportedAsHolder() async throws {
        let tracker = DeviceIOTracker()
        let smartToken = try await tracker.beginTargetOperation(physicalBSDName: "disk4", kind: .smart)
        let holder = OccupancyHolder(
            pid: 501,
            executableName: "Finder",
            displayName: nil,
            type: .openFileOrDirectory
        )
        let operations = IntegrationDAOperations(
            normalUnmount: .failure(status: DAReturn(kDAReturnBusy), message: "Volume is in use")
        )
        let scanner = OccupancyScanner(
            appScanner: IntegrationAppScanner(result: .init(holders: [holder], isComplete: true)),
            helperScanner: IntegrationHelperScanner(result: .init(holders: [], isComplete: true))
        )
        let coordinator = EjectCoordinator(
            resolver: IntegrationResolver(initial: .success(.init(target: target, scope: scope))),
            quiescer: DeviceIOQuiescer(tracker: tracker),
            ejecter: DiskArbitrationEjectClient(
                operations: operations
            ),
            occupancyScanner: scanner,
            preparationTimeout: .seconds(1)
        )

        coordinator.begin(deviceID: target.deviceID, displayName: target.displayName, topologyGeneration: 9)
        try await waitUntil { if case .working(_, .preparing) = coordinator.state { true } else { false } }
        await tracker.finish(smartToken)
        try await waitUntil { coordinator.state.recovery != nil }

        let daUnmountCalls = await operations.unmountCallCount()
        XCTAssertEqual(daUnmountCalls, 1)
        XCTAssertEqual(coordinator.state.recovery?.holders.map(\.preferredName), ["Finder"])
        XCTAssertFalse(coordinator.state.recovery?.holders.contains { $0.preferredName == "DrivePulse" } == true)
    }

    func testForceFailuresNeverProduceSafeRemovalState() async throws {
        let forceUnmountFailure = EjectFailure(
            stage: .forceUnmounting,
            category: .io,
            rawStatus: nil,
            systemMessage: nil,
            physicalBSDName: "disk4",
            holders: []
        )
        let first = makeCoordinator(
            ejecter: IntegrationDiskEjecter(
                normal: .failure(busyFailure),
                force: .failure(forceUnmountFailure)
            ),
            scanner: IntegrationOccupancyScanner()
        )
        first.coordinator.begin(deviceID: target.deviceID, displayName: target.displayName, topologyGeneration: 9)
        try await waitUntil { first.coordinator.state.recovery != nil }
        first.coordinator.requestForce()
        first.coordinator.confirmForce()
        try await waitUntil { first.coordinator.state.failure?.stage == .forceUnmounting }
        XCTAssertFalse(first.coordinator.state.isSuccessful)

        let operations = IntegrationDAOperations(
            normalUnmount: .failure(status: DAReturn(kDAReturnBusy), message: "Volume is in use"),
            forceUnmount: .success,
            ejectResult: .failure(status: DAReturn(kDAReturnError), message: "transport")
        )
        let second = makeCoordinator(
            ejecter: DiskArbitrationEjectClient(
                operations: operations
            ),
            scanner: IntegrationOccupancyScanner()
        )
        second.coordinator.begin(deviceID: target.deviceID, displayName: target.displayName, topologyGeneration: 9)
        try await waitUntil { second.coordinator.state.recovery != nil }
        second.coordinator.requestForce()
        second.coordinator.confirmForce()
        try await waitUntil { second.coordinator.state.failure?.stage == .ejecting }
        XCTAssertFalse(second.coordinator.state.isSuccessful)
    }

    func testAPFSAndNonAPFSScopesContainOnlyExactDescendants() async throws {
        let apfsResolver = LiveEjectTargetResolver(snapshotProvider: IntegrationSnapshotProvider(media: [
            media("disk4", whole: true, children: ["disk4s1"], container: "disk8"),
            media("disk4s1"),
            media("disk8", whole: true, children: ["disk8s1", "disk8s2"]),
            media("disk8s1", mount: "/Volumes/Data"),
            media("disk8s2", mount: "/Volumes/Backup"),
            media("disk40", whole: true, children: ["disk40s1"]),
            media("disk40s1", mount: "/Volumes/Database")
        ]))
        let nonAPFSResolver = LiveEjectTargetResolver(snapshotProvider: IntegrationSnapshotProvider(media: [
            media("disk4", whole: true, children: ["disk4s1", "disk4s2"]),
            media("disk4s1", mount: "/Volumes/Data"),
            media("disk4s2", mount: "/Volumes/Archive"),
            media("disk40", whole: true, children: ["disk40s1"]),
            media("disk40s1", mount: "/Volumes/Database")
        ]))

        let apfs = try await apfsResolver.resolve(deviceID: target.deviceID, displayName: "T7", topologyGeneration: 9)
        let nonAPFS = try await nonAPFSResolver.resolve(deviceID: target.deviceID, displayName: "T7", topologyGeneration: 9)

        XCTAssertTrue(apfs.scope.contains(path: "/Volumes/Data/report"))
        XCTAssertTrue(apfs.scope.contains(path: "/Volumes/Backup/report"))
        XCTAssertFalse(apfs.scope.contains(path: "/Volumes/Database/report"))
        XCTAssertTrue(nonAPFS.scope.contains(path: "/Volumes/Archive/report"))
        XCTAssertFalse(nonAPFS.scope.contains(deviceNode: "/dev/disk40s1"))
    }

    func testReassignmentDuringRecoveryPreventsRetryOrForceAgainstReplacement() async throws {
        let resolver = IntegrationResolver(
            initial: .success(.init(target: target, scope: scope)),
            revalidations: [
                .success(.init(target: target, scope: scope)),
                .failure(EjectTargetResolutionError.targetChanged)
            ]
        )
        let ejecter = IntegrationDiskEjecter(normal: .failure(busyFailure), force: .success(()))
        let coordinator = EjectCoordinator(
            resolver: resolver,
            quiescer: IntegrationQuiescer(),
            ejecter: ejecter,
            occupancyScanner: IntegrationOccupancyScanner()
        )

        coordinator.begin(deviceID: target.deviceID, displayName: target.displayName, topologyGeneration: 9)
        try await waitUntil { coordinator.state.recovery != nil }
        coordinator.retry()
        try await waitUntil { if case .disappeared = coordinator.state { true } else { false } }

        let normalCalls = await ejecter.normalCallCount()
        let forceCallsBefore = await ejecter.forceCallCount()
        XCTAssertEqual(normalCalls, 1)
        XCTAssertEqual(forceCallsBefore, 0)
        coordinator.requestForce()
        coordinator.confirmForce()
        let forceCallsAfter = await ejecter.forceCallCount()
        XCTAssertEqual(forceCallsAfter, 0)
    }

    private let target = EjectWorkflowTarget(
        deviceID: DeviceID(rawValue: "serial:fixture"),
        physicalBSDName: "disk4",
        mediaRegistryEntryID: 4001,
        displayName: "Fixture Disk",
        topologyGeneration: 9
    )

    private var scope: OccupancyTargetScope {
        .init(
            physicalBSDName: "disk4",
            deviceNodes: ["/dev/disk4", "/dev/rdisk4", "/dev/disk4s1"],
            mountURLs: [URL(fileURLWithPath: "/Volumes/Fixture")]
        )
    }

    private var busyFailure: EjectFailure {
        .init(
            stage: .unmounting,
            category: .busy,
            rawStatus: Int32(bitPattern: 0x0000_C010),
            systemMessage: nil,
            physicalBSDName: "disk4",
            holders: []
        )
    }

    private func makeCoordinator(
        ejecter: any DiskEjecting,
        scanner: any OccupancyScanning
    ) -> (coordinator: EjectCoordinator, resolver: IntegrationResolver) {
        let resolver = IntegrationResolver(initial: .success(.init(target: target, scope: scope)))
        return (
            EjectCoordinator(
                resolver: resolver,
                quiescer: IntegrationQuiescer(),
                ejecter: ejecter,
                occupancyScanner: scanner
            ),
            resolver
        )
    }

    private func media(
        _ bsdName: String,
        whole: Bool = false,
        children: [String] = [],
        container: String? = nil,
        mount: String? = nil
    ) -> EjectMediaSnapshot {
        .init(
            deviceID: whole && bsdName == "disk4" ? target.deviceID : nil,
            bsdName: bsdName,
            registryEntryID: whole ? UInt64(abs(bsdName.hashValue)) : nil,
            isWhole: whole,
            isExternal: whole,
            isEjectable: whole,
            childBSDNames: children,
            wholeDiskBSDName: whole ? bsdName : nil,
            apfsContainerBSDName: container,
            mountURL: mount.map(URL.init(fileURLWithPath:))
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while await predicate() == false {
            guard ContinuousClock.now < deadline else {
                throw IntegrationTestError.timedOut
            }
            await Task.yield()
        }
    }
}

private enum IntegrationTestError: Error { case timedOut }

private actor IntegrationResolver: EjectTargetResolving {
    private let initial: Result<ResolvedEjectTarget, Error>
    private var revalidations: [Result<ResolvedEjectTarget, Error>]

    init(
        initial: Result<ResolvedEjectTarget, Error>,
        revalidations: [Result<ResolvedEjectTarget, Error>] = []
    ) {
        self.initial = initial
        self.revalidations = revalidations
    }

    func resolve(deviceID: DeviceID, displayName: String, topologyGeneration: Int) async throws -> ResolvedEjectTarget {
        try initial.get()
    }

    func revalidate(_ target: EjectWorkflowTarget) async throws -> ResolvedEjectTarget {
        if revalidations.isEmpty { return try initial.get() }
        return try revalidations.removeFirst().get()
    }
}

private struct IntegrationQuiescer: DeviceIOQuiescing {
    func acquireBarrier(for target: EjectWorkflowTarget, timeout: Duration) async throws(DeviceIOQuiescenceError) -> any EjectBarrier {
        IntegrationBarrier()
    }
}

private struct IntegrationBarrier: EjectBarrier {
    func waitUntilReady() async throws {}
    func release() async {}
}

private actor IntegrationDAOperations: DiskArbitrationOperating {
    private let normalUnmount: DiskArbitrationOperationResult
    private let forceUnmount: DiskArbitrationOperationResult
    private let ejectResult: DiskArbitrationOperationResult
    private var unmountCalls = 0

    init(
        normalUnmount: DiskArbitrationOperationResult = .success,
        forceUnmount: DiskArbitrationOperationResult = .success,
        ejectResult: DiskArbitrationOperationResult = .success
    ) {
        self.normalUnmount = normalUnmount
        self.forceUnmount = forceUnmount
        self.ejectResult = ejectResult
    }

    func performWholeDiskEject(
        plan: DiskEjectOperationPlan,
        force: Bool
    ) async -> DiskArbitrationSequenceResult {
        _ = plan
        unmountCalls += 1
        let result = force ? forceUnmount : normalUnmount
        switch result {
        case .success:
            return ejectResult == .success
                ? .success
                : .failure(result: ejectResult, stage: .ejecting)
        case .failure(let status, _) where DiskArbitrationErrorClassifier().classify(status) == .notMounted:
            return ejectResult == .success
                ? .success
                : .failure(result: ejectResult, stage: .ejecting)
        default:
            return .failure(result: result, stage: force ? .forceUnmounting : .unmounting)
        }
    }

    func unmountCallCount() -> Int { unmountCalls }
}

private actor IntegrationDiskEjecter: DiskEjecting {
    private let normal: DiskEjectOutcome
    private let force: DiskEjectOutcome
    private var normalCalls = 0
    private var forceCalls = 0

    init(normal: DiskEjectOutcome, force: DiskEjectOutcome) {
        self.normal = normal
        self.force = force
    }

    func performNormalEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome {
        _ = plan
        normalCalls += 1
        return normal
    }

    func performConfirmedForceEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome {
        _ = plan
        forceCalls += 1
        return force
    }

    func normalCallCount() -> Int { normalCalls }
    func forceCallCount() -> Int { forceCalls }
}

private struct IntegrationAppScanner: AppOccupancyScanning {
    let result: OccupancyScanResult
    func scan(scope: OccupancyTargetScope, deadline: ContinuousClock.Instant) async -> OccupancyScanResult { result }
}

private actor IntegrationHelperScanner: HelperOccupancyScanning {
    private let result: OccupancyScanResult
    private var calls = 0

    init(result: OccupancyScanResult) { self.result = result }
    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult {
        calls += 1
        return result
    }
    func callCount() -> Int { calls }
}

private struct FailingIntegrationHelperScanner: HelperOccupancyScanning {
    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult {
        throw IntegrationTestError.timedOut
    }
}

private struct IntegrationOccupancyScanner: OccupancyScanning {
    func scan(workflowID: UUID, scope: OccupancyTargetScope) async -> OccupancyScanResult {
        .init(holders: [], isComplete: false)
    }
}

private struct IntegrationSnapshotProvider: EjectTargetSnapshotProviding {
    let media: [EjectMediaSnapshot]
    func currentMedia() async throws -> [EjectMediaSnapshot] { media }
}

private extension EjectWorkflowState {
    var recovery: EjectRecoveryState? {
        switch self {
        case .awaitingRecovery(let recovery), .awaitingForceConfirmation(let recovery): recovery
        default: nil
        }
    }

    var failure: EjectFailure? {
        guard case .failed(_, let failure) = self else { return nil }
        return failure
    }

    var isSuccessful: Bool {
        if case .succeeded = self { return true }
        return false
    }
}
