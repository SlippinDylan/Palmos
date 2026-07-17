import DiskArbitration
import Foundation
import XCTest
@testable import DrivePulseApp

final class DiskArbitrationEjectClientTests: XCTestCase {
    func testNormalEjectUsesMountedVolumeWithAllPartitionsAndNoUI() async {
        let operations = StubDiskArbitrationOperating(results: [])
        let volumeUnmounter = StubVolumeUnmounting(error: nil)
        let client = DiskArbitrationEjectClient(
            operations: operations,
            volumeUnmounter: volumeUnmounter
        )
        let mountURL = URL(fileURLWithPath: "/Volumes/T7")

        let result = await client.performNormalEject(
            bsdName: "disk4",
            scope: scope(mountURLs: [mountURL])
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(volumeUnmounter.calls, [
            .init(url: mountURL, options: [.allPartitionsAndEjectDisk, .withoutUI])
        ])
        XCTAssertEqual(operations.calls, [])
    }

    func testNormalEjectWithoutMountedVolumeEjectsPhysicalDiskDirectly() async {
        let operations = StubDiskArbitrationOperating(results: [.success])
        let volumeUnmounter = StubVolumeUnmounting(error: nil)
        let client = DiskArbitrationEjectClient(
            operations: operations,
            volumeUnmounter: volumeUnmounter
        )

        let result = await client.performNormalEject(
            bsdName: "disk4",
            scope: scope(mountURLs: [])
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(volumeUnmounter.calls, [])
        XCTAssertEqual(operations.calls, [.eject("disk4")])
    }

    func testConfirmedForceEjectUsesForcedWholeUnmountBeforeEjecting() async {
        let adapter = StubDiskArbitrationOperating(results: [.success, .success])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: true), .eject("disk4")])
    }

    func testForceNotMountedUnmountContinuesToEject() async {
        let adapter = StubDiskArbitrationOperating(results: [
            .failure(status: DAReturn(kDAReturnNotMounted), message: nil), .success
        ])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: true), .eject("disk4")])
    }

    func testNormalEjectFailureIncludesDissentingProcessHolder() async {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EBUSY),
            userInfo: [
                NSFileManagerUnmountDissentingProcessIdentifierErrorKey: NSNumber(value: 501),
                NSLocalizedDescriptionKey: "Volume is in use"
            ]
        )
        let holder = OccupancyHolder(
            pid: 501,
            executableName: "Finder",
            displayName: "Finder",
            type: .unknown
        )
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: []),
            volumeUnmounter: StubVolumeUnmounting(error: error),
            dissentingProcessIdentifier: StubDissentingProcessIdentifying(holder: holder)
        )

        let result = await client.performNormalEject(
            bsdName: "disk4",
            scope: scope(mountURLs: [URL(fileURLWithPath: "/Volumes/T7")])
        )

        XCTAssertEqual(result.failure?.stage, .unmounting)
        XCTAssertEqual(result.failure?.category, .busy)
        XCTAssertEqual(result.failure?.rawStatus, EBUSY)
        XCTAssertEqual(result.failure?.systemMessage, "Volume is in use")
        XCTAssertEqual(result.failure?.physicalBSDName, "disk4")
        XCTAssertEqual(result.failure?.holders, [holder])
    }

    func testNormalEjectClassifiesPOSIXPermissionFailure() async {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: []),
            volumeUnmounter: StubVolumeUnmounting(error: error)
        )

        let result = await client.performNormalEject(
            bsdName: "disk4",
            scope: scope(mountURLs: [URL(fileURLWithPath: "/Volumes/T7")])
        )

        XCTAssertEqual(result.failure?.category, .notPermitted)
    }

    func testNormalEjectClassifiesCocoaPermissionFailure() async {
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: []),
            volumeUnmounter: StubVolumeUnmounting(error: error)
        )

        let result = await client.performNormalEject(
            bsdName: "disk4",
            scope: scope(mountURLs: [URL(fileURLWithPath: "/Volumes/T7")])
        )

        XCTAssertEqual(result.failure?.category, .notPermitted)
    }

    func testForceUnmountTimeoutReportsForceUnmountingStage() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [.timedOut])
        )

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertEqual(result.failure?.stage, .forceUnmounting)
        XCTAssertEqual(result.failure?.category, .timedOut)
    }

    func testDirectEjectTimeoutReportsEjectingStage() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [.timedOut])
        )

        let result = await client.performNormalEject(
            bsdName: "disk4",
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

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: true)])
        XCTAssertEqual(result.failure?.stage, .forceUnmounting)
    }

    func testForcedUnmountFailurePreservesRawStatusMessageAndPhysicalBSDName() async {
        let status = DAReturn(kDAReturnExclusiveAccess)
        let client = DiskArbitrationEjectClient(operations: StubDiskArbitrationOperating(results: [
            .failure(status: status, message: "system detail")
        ]))

        let result = await client.performConfirmedForceEject(bsdName: "disk99")

        XCTAssertEqual(result.failure?.rawStatus, status)
        XCTAssertEqual(result.failure?.systemMessage, "system detail")
        XCTAssertEqual(result.failure?.physicalBSDName, "disk99")
    }

    func testForceUnmountSuccessThenEjectFailureRemainsEjectingFailure() async {
        let adapter = StubDiskArbitrationOperating(results: [
            .success, .failure(status: DAReturn(kDAReturnNotReady), message: "not ready")
        ])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertEqual(result.failure?.stage, .ejecting)
        XCTAssertEqual(result.failure?.category, .notReady)
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

private final class StubDiskArbitrationOperating: DiskArbitrationOperating, @unchecked Sendable {
    enum Call: Equatable {
        case unmount(String, force: Bool)
        case eject(String)
    }

    private var results: [DiskArbitrationOperationResult]
    private(set) var calls: [Call] = []

    init(results: [DiskArbitrationOperationResult]) { self.results = results }

    func unmountWhole(_ bsdName: String, force: Bool) async -> DiskArbitrationOperationResult {
        calls.append(.unmount(bsdName, force: force))
        return results.removeFirst()
    }

    func eject(_ bsdName: String) async -> DiskArbitrationOperationResult {
        calls.append(.eject(bsdName))
        return results.removeFirst()
    }
}

private final class StubVolumeUnmounting: VolumeUnmounting, @unchecked Sendable {
    struct Call: Equatable {
        let url: URL
        let options: FileManager.UnmountOptions
    }

    private let error: NSError?
    private(set) var calls: [Call] = []

    init(error: NSError?) { self.error = error }

    func unmountVolume(at url: URL, options: FileManager.UnmountOptions) async -> (any Error)? {
        calls.append(Call(url: url, options: options))
        return error
    }
}

private struct StubDissentingProcessIdentifying: DissentingProcessIdentifying {
    let holder: OccupancyHolder

    func holder(for pid: Int32) -> OccupancyHolder {
        XCTAssertEqual(pid, holder.pid)
        return holder
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

private extension Result where Success == Void, Failure == EjectFailure {
    var isSuccess: Bool {
        guard case .success = self else { return false }
        return true
    }

    var failure: EjectFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
