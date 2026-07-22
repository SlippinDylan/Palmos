import DiskArbitration
import Foundation
import XCTest
@testable import DrivePulseApp

final class DiskArbitrationEjectClientTests: XCTestCase {
    private var target: PhysicalDiskTargetIdentity {
        PhysicalDiskTargetIdentity(bsdName: "disk4", mediaRegistryEntryID: 4_001)
    }

    func testForceEjectCarriesStablePhysicalIdentityToEveryDestructiveStage() async {
        let target = PhysicalDiskTargetIdentity(bsdName: "disk4", mediaRegistryEntryID: 4_001)
        let adapter = StubDiskArbitrationOperating(results: [.success, .success])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(target: target)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [
            .unmount(target, force: true),
            .eject(target)
        ])
    }

    func testNormalEjectUsesMountedVolumeWithAllPartitionsAndNoUI() async {
        let operations = StubDiskArbitrationOperating(results: [.success, .success])
        let client = DiskArbitrationEjectClient(operations: operations)

        let result = await client.performNormalEject(
            target: target,
            scope: scope(mountURLs: [URL(fileURLWithPath: "/Volumes/T7")])
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(operations.calls, [.unmount(target, force: false), .eject(target)])
    }

    func testNormalEjectWithoutMountedVolumeEjectsPhysicalDiskDirectly() async {
        let operations = StubDiskArbitrationOperating(results: [.success, .success])
        let client = DiskArbitrationEjectClient(operations: operations)

        let result = await client.performNormalEject(
            target: target,
            scope: scope(mountURLs: [])
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(operations.calls, [.unmount(target, force: false), .eject(target)])
    }

    func testAPFSContainerIsDetachedBeforeBackingPhysicalDisk() async {
        let logicalTarget = DiskArbitrationWholeDiskIdentity(
            bsdName: "disk7",
            mediaRegistryEntryID: 7_001
        )
        let operations = StubDiskArbitrationOperating(results: [
            .success, .success, .success, .success
        ])
        let client = DiskArbitrationEjectClient(operations: operations)

        let result = await client.performNormalEject(
            plan: DiskEjectOperationPlan(
                physicalTarget: PhysicalDiskTargetIdentity(
                    bsdName: "disk6",
                    mediaRegistryEntryID: 6_001
                ),
                logicalWholeDiskTargets: [logicalTarget]
            )
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(operations.calls, [
            .logicalUnmount(logicalTarget, force: false),
            .logicalEject(logicalTarget),
            .unmount(
                PhysicalDiskTargetIdentity(bsdName: "disk6", mediaRegistryEntryID: 6_001),
                force: false
            ),
            .eject(PhysicalDiskTargetIdentity(bsdName: "disk6", mediaRegistryEntryID: 6_001))
        ])
    }

    func testConfirmedForceEjectUsesForcedWholeUnmountBeforeEjecting() async {
        let adapter = StubDiskArbitrationOperating(results: [.success, .success])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(target: target)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [.unmount(target, force: true), .eject(target)])
    }

    func testForceNotMountedUnmountContinuesToEject() async {
        let adapter = StubDiskArbitrationOperating(results: [
            .failure(status: DAReturn(kDAReturnNotMounted), message: nil), .success
        ])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(target: target)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [.unmount(target, force: true), .eject(target)])
    }

    func testNormalEjectFailureIncludesDissentingProcessHolder() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [
                .failure(status: DAReturn(kDAReturnBusy), message: "Volume is in use")
            ])
        )

        let result = await client.performNormalEject(
            target: target,
            scope: scope(mountURLs: [URL(fileURLWithPath: "/Volumes/T7")])
        )

        XCTAssertEqual(result.failure?.stage, .unmounting)
        XCTAssertEqual(result.failure?.category, .busy)
        XCTAssertEqual(result.failure?.rawStatus, DAReturn(kDAReturnBusy))
        XCTAssertEqual(result.failure?.systemMessage, "Volume is in use")
        XCTAssertEqual(result.failure?.physicalBSDName, "disk4")
        XCTAssertEqual(result.failure?.holders, [])
    }

    func testNormalEjectClassifiesPOSIXPermissionFailure() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [
                .failure(status: DAReturn(kDAReturnNotPermitted), message: nil)
            ])
        )

        let result = await client.performNormalEject(
            target: target,
            scope: scope(mountURLs: [URL(fileURLWithPath: "/Volumes/T7")])
        )

        XCTAssertEqual(result.failure?.category, .notPermitted)
    }

    func testNormalEjectClassifiesCocoaPermissionFailure() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [
                .failure(status: DAReturn(kDAReturnNotPermitted), message: nil)
            ])
        )

        let result = await client.performNormalEject(
            target: target,
            scope: scope(mountURLs: [URL(fileURLWithPath: "/Volumes/T7")])
        )

        XCTAssertEqual(result.failure?.category, .notPermitted)
    }

    func testForceUnmountTimeoutReportsForceUnmountingStage() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [.timedOut])
        )

        let result = await client.performConfirmedForceEject(target: target)

        XCTAssertEqual(result.failure?.stage, .forceUnmounting)
        XCTAssertEqual(result.failure?.category, .timedOut)
    }

    func testDirectEjectTimeoutReportsEjectingStage() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [.success, .timedOut])
        )

        let result = await client.performNormalEject(
            target: target,
            scope: scope(mountURLs: [])
        )

        XCTAssertEqual(result.failure?.stage, .ejecting)
        XCTAssertEqual(result.failure?.category, .timedOut)
    }

    func testForcedUnmountFailureStopsBeforeEject() async {
        let adapter = StubDiskArbitrationOperating(results: [
            .failure(status: DAReturn(kDAReturnNotPermitted), message: nil)
        ])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(target: target)

        XCTAssertEqual(adapter.calls, [.unmount(target, force: true)])
        XCTAssertEqual(result.failure?.stage, .forceUnmounting)
    }

    func testForcedUnmountFailurePreservesRawStatusMessageAndPhysicalBSDName() async {
        let status = DAReturn(kDAReturnExclusiveAccess)
        let client = DiskArbitrationEjectClient(operations: StubDiskArbitrationOperating(results: [
            .failure(status: status, message: "system detail")
        ]))

        let result = await client.performConfirmedForceEject(
            target: PhysicalDiskTargetIdentity(bsdName: "disk99", mediaRegistryEntryID: 9_999)
        )

        XCTAssertEqual(result.failure?.rawStatus, status)
        XCTAssertEqual(result.failure?.systemMessage, "system detail")
        XCTAssertEqual(result.failure?.physicalBSDName, "disk99")
    }

    func testForceUnmountSuccessThenEjectFailureRemainsEjectingFailure() async {
        let adapter = StubDiskArbitrationOperating(results: [
            .success, .failure(status: DAReturn(kDAReturnNotReady), message: "not ready")
        ])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(target: target)

        XCTAssertEqual(result.failure?.stage, .ejecting)
        XCTAssertEqual(result.failure?.category, .notReady)
    }

    func testForceEjectRejectsRegistryReassignmentBetweenUnmountAndEject() {
        let probe = BoundSequenceProbe(targetValidationResults: [false])
        let gate = BoundDiskArbitrationSecondStageGate(
            targetIsValid: probe.targetIsValid,
            submitEject: probe.submitEject
        )

        let transition = gate.proceedAfterUnmount(.success, stage: .forceUnmounting)

        XCTAssertEqual(transition, .finished(.targetInvalidated(stage: .ejecting)))
        XCTAssertEqual(probe.validationCount, 1)
        XCTAssertEqual(probe.ejectCount, 0)
    }

    func testNotMountedForcePathRevalidatesBeforeEject() {
        let probe = BoundSequenceProbe(targetValidationResults: [false])
        let gate = BoundDiskArbitrationSecondStageGate(
            targetIsValid: probe.targetIsValid,
            submitEject: probe.submitEject
        )

        let transition = gate.proceedAfterUnmount(
            .failure(status: DAReturn(kDAReturnNotMounted), message: nil),
            stage: .forceUnmounting
        )

        XCTAssertEqual(transition, .finished(.targetInvalidated(stage: .ejecting)))
        XCTAssertEqual(probe.validationCount, 1)
        XCTAssertEqual(probe.ejectCount, 0)
    }

    func testSameBoundIdentityContinuesToEjectAfterUnmount() {
        let probe = BoundSequenceProbe(targetValidationResults: [true])
        let gate = BoundDiskArbitrationSecondStageGate(
            targetIsValid: probe.targetIsValid,
            submitEject: probe.submitEject
        )

        let transition = gate.proceedAfterUnmount(.success, stage: .unmounting)

        XCTAssertEqual(transition, .ejectSubmitted)
        XCTAssertEqual(probe.validationCount, 1)
        XCTAssertEqual(probe.ejectCount, 1)
    }

    func testCallbackWinningTimeoutResumesAndCleansUpExactlyOnce() {
        assertRegistryRace(events: [.callback(.success), .timeout], expected: .success)
    }

    func testTimeoutWinningCallbackResumesAndCleansUpBeforeLateCallback() {
        assertRegistryRace(events: [.timeout, .callback(.success)], expected: .timedOut)
    }

    func testCancellationWinningCallbackAndLateTimeoutResumesAndCleansUpImmediately() {
        assertRegistryRace(events: [.cancelled, .timeout, .callback(.success)], expected: .cancelled)
    }

    func testTimedOutContextCannotAliasNewOperationBeforeLateCallback() {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry(cleanupObserver: { probe.recordCleanup($0) })
        let oldContext = registry.register { probe.record($0) }
        registry.resolve(context: oldContext, event: .timeout)

        let newContext = registry.register { probe.record($0) }

        XCTAssertNotEqual(oldContext.rawValue, newContext.rawValue)
        registry.resolveCallback(context: oldContext.unsafeContext, result: .success)
        registry.resolveCallback(context: newContext.unsafeContext, result: .success)
        XCTAssertEqual(probe.results, [.timedOut, .success])
        XCTAssertEqual(Set(probe.cleanedContextKeys).count, 2)
        XCTAssertEqual(registry.registeredContextCount, 0)
    }

    func testCancellationBeforeContextInstallWinsAndCleansUpAtInstall() {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry(cleanupObserver: { probe.recordCleanup($0) })
        let cancellation = DiskArbitrationOperationCancellation(registry: registry)
        cancellation.cancel()
        let context = registry.register { probe.record($0) }

        cancellation.install(context)
        registry.resolve(context: context, event: .timeout)
        registry.resolveCallback(context: context, result: .success)

        XCTAssertEqual(probe.results, [.cancelled])
        XCTAssertEqual(probe.cleanedContextKeys, [context.rawValue])
        XCTAssertEqual(registry.registeredContextCount, 0)
    }

    func testTimeoutCleansUpWithoutAnyCallback() {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry(cleanupObserver: { probe.recordCleanup($0) })
        let context = registry.register(resume: { probe.record($0) }, cleanup: { probe.recordResourceCleanup() })

        registry.resolve(context: context, event: .timeout)

        XCTAssertEqual(probe.results, [.timedOut])
        XCTAssertEqual(probe.cleanedContextKeys, [context.rawValue])
        XCTAssertEqual(probe.resourceCleanupCount, 1)
        XCTAssertEqual(registry.registeredContextCount, 0)
    }

    func testCancellationCleansUpWithoutAnyCallback() {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry(cleanupObserver: { probe.recordCleanup($0) })
        let context = registry.register(resume: { probe.record($0) }, cleanup: { probe.recordResourceCleanup() })

        registry.resolve(context: context, event: .cancelled)

        XCTAssertEqual(probe.results, [.cancelled])
        XCTAssertEqual(probe.resourceCleanupCount, 1)
        XCTAssertEqual(registry.registeredContextCount, 0)
    }

    func testStaleCallbackCannotCompleteNewOperationAfterTerminalCleanup() {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry()
        let staleContext = registry.register { probe.record($0) }
        registry.resolve(context: staleContext, event: .timeout)

        var newContexts: [DiskArbitrationCallbackToken] = []
        for _ in 0..<1_000 {
            let context = registry.register { probe.record($0) }
            newContexts.append(context)
        }

        XCTAssertFalse(newContexts.contains { $0.rawValue == staleContext.rawValue })
        registry.resolveCallback(context: staleContext.unsafeContext, result: .success)
        XCTAssertEqual(probe.results, [.timedOut])

        for context in newContexts {
            registry.resolve(context: context, event: .cancelled)
        }
        XCTAssertEqual(registry.registeredContextCount, 0)
    }

    func testConcurrentCallbackTimeoutAndCancellationHaveExactlyOneWinnerAndCleanup() {
        for _ in 0..<100 {
            let probe = CompletionProbe()
            let registry = DiskArbitrationCallbackRegistry()
            let context = registry.register(resume: { probe.record($0) }, cleanup: { probe.recordResourceCleanup() })
            let contendersQueue = DispatchQueue(
                label: "DiskArbitrationEjectClientTests.contenders",
                qos: .userInitiated,
                attributes: [.concurrent, .initiallyInactive]
            )
            let finished = DispatchGroup()
            let contenders: [@Sendable () -> Void] = [
                { registry.resolveCallback(context: context, result: .success) },
                { registry.resolve(context: context, event: .timeout) },
                { registry.resolve(context: context, event: .cancelled) }
            ]

            for contender in contenders {
                finished.enter()
                contendersQueue.async {
                    contender()
                    finished.leave()
                }
            }
            contendersQueue.activate()
            finished.wait()

            XCTAssertEqual(probe.results.count, 1)
            XCTAssertEqual(probe.resourceCleanupCount, 1)
            XCTAssertEqual(registry.registeredContextCount, 0)
        }
    }

    func testCancellationBeforeSubmitPreventsDestructiveOperation() {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry()
        let gate = DiskArbitrationOperationCancellation(registry: registry)
        gate.cancel()
        let context = registry.register { probe.record($0) }
        gate.install(context)

        let submitted = gate.submit { probe.recordSubmit() }

        XCTAssertFalse(submitted)
        XCTAssertEqual(probe.submitCount, 0)
        XCTAssertEqual(probe.results, [.cancelled])
    }

    func testInstallSubmitRaceNeverSubmitsAfterTerminalCancellation() {
        for _ in 0..<100 {
            let probe = CompletionProbe()
            let registry = DiskArbitrationCallbackRegistry()
            let gate = DiskArbitrationOperationCancellation(registry: registry)
            let context = registry.register { probe.record($0) }
            gate.install(context)
            let contendersQueue = DispatchQueue(
                label: "DiskArbitrationEjectClientTests.submissionContenders",
                qos: .userInitiated,
                attributes: [.concurrent, .initiallyInactive]
            )
            let finished = DispatchGroup()

            finished.enter()
            contendersQueue.async {
                gate.cancel()
                finished.leave()
            }
            finished.enter()
            contendersQueue.async {
                _ = gate.submit { probe.recordSubmit() }
                finished.leave()
            }
            contendersQueue.activate()
            finished.wait()

            if probe.results == [.cancelled], probe.submitCount == 1 {
                XCTAssertEqual(probe.timeline, ["submit", "cancelled"])
            }
            XCTAssertLessThanOrEqual(probe.submitCount, 1)
        }
    }

    private func assertRegistryRace(
        events: [RegistryEvent],
        expected: DiskArbitrationOperationResult
    ) {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry(cleanupObserver: { probe.recordCleanup($0) })
        let context = registry.register { probe.record($0) }

        for event in events {
            switch event {
            case .callback(let result): registry.resolveCallback(context: context, result: result)
            case .timeout: registry.resolve(context: context, event: .timeout)
            case .cancelled: registry.resolve(context: context, event: .cancelled)
            }
        }

        XCTAssertEqual(probe.results, [expected])
        XCTAssertEqual(probe.cleanedContextKeys, [context.rawValue])
        XCTAssertEqual(registry.registeredContextCount, 0)
    }

    private func scope(mountURLs: Set<URL>) -> OccupancyTargetScope {
        OccupancyTargetScope(
            physicalBSDName: "disk4",
            deviceNodes: ["/dev/disk4"],
            mountURLs: mountURLs
        )
    }
}

private enum RegistryEvent {
    case callback(DiskArbitrationOperationResult)
    case timeout
    case cancelled
}

private final class BoundSequenceProbe {
    private var targetValidationResults: [Bool]
    private(set) var validationCount = 0
    private(set) var ejectCount = 0

    init(targetValidationResults: [Bool]) {
        self.targetValidationResults = targetValidationResults
    }

    func targetIsValid() -> Bool {
        validationCount += 1
        return targetValidationResults.removeFirst()
    }

    func submitEject() {
        ejectCount += 1
    }
}

private final class StubDiskArbitrationOperating: DiskArbitrationOperating, @unchecked Sendable {
    enum Call: Equatable {
        case logicalUnmount(DiskArbitrationWholeDiskIdentity, force: Bool)
        case logicalEject(DiskArbitrationWholeDiskIdentity)
        case unmount(PhysicalDiskTargetIdentity, force: Bool)
        case eject(PhysicalDiskTargetIdentity)
    }

    private var results: [DiskArbitrationOperationResult]
    private(set) var calls: [Call] = []

    init(results: [DiskArbitrationOperationResult]) { self.results = results }

    func performWholeDiskEject(
        plan: DiskEjectOperationPlan,
        force: Bool
    ) async -> DiskArbitrationSequenceResult {
        let unmountStage: EjectOperationStage = force ? .forceUnmounting : .unmounting
        for logicalTarget in plan.logicalWholeDiskTargets {
            calls.append(.logicalUnmount(logicalTarget, force: force))
            let logicalUnmountResult = results.removeFirst()
            switch logicalUnmountResult {
            case .success:
                break
            case .failure(let status, _)
                where DiskArbitrationErrorClassifier().classify(status) == .notMounted:
                break
            default:
                return .failure(result: logicalUnmountResult, stage: unmountStage)
            }

            calls.append(.logicalEject(logicalTarget))
            let logicalEjectResult = results.removeFirst()
            guard logicalEjectResult == .success else {
                return .failure(result: logicalEjectResult, stage: .ejecting)
            }
        }

        let target = plan.physicalTarget
        calls.append(.unmount(target, force: force))
        let unmountResult = results.removeFirst()
        switch unmountResult {
        case .success:
            break
        case .failure(let status, _) where DiskArbitrationErrorClassifier().classify(status) == .notMounted:
            break
        default:
            return .failure(result: unmountResult, stage: unmountStage)
        }

        calls.append(.eject(target))
        let ejectResult = results.removeFirst()
        return ejectResult == .success
            ? .success
            : .failure(result: ejectResult, stage: .ejecting)
    }
}

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [DiskArbitrationOperationResult] = []
    private(set) var cleanedContextKeys: [UInt] = []
    private(set) var resourceCleanupCount = 0
    private(set) var submitCount = 0
    private(set) var timeline: [String] = []

    func record(_ result: DiskArbitrationOperationResult) {
        lock.withLock {
            results.append(result)
            if result == .cancelled { timeline.append("cancelled") }
        }
    }

    func recordCleanup(_ key: UInt) {
        lock.withLock { cleanedContextKeys.append(key) }
    }

    func recordResourceCleanup() {
        lock.withLock { resourceCleanupCount += 1 }
    }

    func recordSubmit() {
        lock.withLock {
            submitCount += 1
            timeline.append("submit")
        }
    }
}
