import DiskArbitration
import XCTest
@testable import DrivePulseApp

final class DiskArbitrationEjectClientTests: XCTestCase {
    func testNormalEjectUnmountsWholeDiskBeforeEjecting() async {
        let adapter = StubDiskArbitrationOperating(results: [.success, .success])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performNormalEject(bsdName: "disk4")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: false), .eject("disk4")])
    }

    func testUnmountFailureStopsBeforeEject() async {
        let adapter = StubDiskArbitrationOperating(results: [.failure(status: DAReturn(kDAReturnBusy), message: "busy")])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performNormalEject(bsdName: "disk4")

        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: false)])
        XCTAssertEqual(result.failure?.stage, .unmounting)
        XCTAssertEqual(result.failure?.category, .busy)
    }

    func testConfirmedForceEjectUsesForcedWholeUnmountBeforeEjecting() async {
        let adapter = StubDiskArbitrationOperating(results: [.success, .success])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: true), .eject("disk4")])
    }

    func testNotMountedUnmountContinuesToEject() async {
        let adapter = StubDiskArbitrationOperating(results: [
            .failure(status: DAReturn(kDAReturnNotMounted), message: nil), .success
        ])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performNormalEject(bsdName: "disk4")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: false), .eject("disk4")])
    }

    func testTimeoutReportsCurrentStage() async {
        let adapter = StubDiskArbitrationOperating(results: [.timedOut])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let normal = await client.performNormalEject(bsdName: "disk4")

        XCTAssertEqual(normal.failure?.stage, .unmounting)
        XCTAssertEqual(normal.failure?.category, .timedOut)
        XCTAssertEqual(adapter.calls, [.unmount("disk4", force: false)])
    }

    func testForceUnmountTimeoutReportsForceUnmountingStage() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [.timedOut])
        )

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertEqual(result.failure?.stage, .forceUnmounting)
        XCTAssertEqual(result.failure?.category, .timedOut)
    }

    func testEjectTimeoutReportsEjectingStage() async {
        let client = DiskArbitrationEjectClient(
            operations: StubDiskArbitrationOperating(results: [.success, .timedOut])
        )

        let result = await client.performNormalEject(bsdName: "disk4")

        XCTAssertEqual(result.failure?.stage, .ejecting)
        XCTAssertEqual(result.failure?.category, .timedOut)
    }

    func testFailurePreservesRawStatusMessageAndPhysicalBSDName() async {
        let status = DAReturn(kDAReturnExclusiveAccess)
        let client = DiskArbitrationEjectClient(operations: StubDiskArbitrationOperating(results: [
            .failure(status: status, message: "system detail")
        ]))

        let result = await client.performNormalEject(bsdName: "disk99")

        XCTAssertEqual(result.failure?.rawStatus, status)
        XCTAssertEqual(result.failure?.systemMessage, "system detail")
        XCTAssertEqual(result.failure?.physicalBSDName, "disk99")
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

        XCTAssertNotEqual(UInt(bitPattern: oldContext), UInt(bitPattern: newContext))
        registry.resolveCallback(context: oldContext, result: .success)
        registry.resolveCallback(context: newContext, result: .success)
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
        XCTAssertEqual(probe.cleanedContextKeys, [UInt(bitPattern: context)])
        XCTAssertEqual(registry.registeredContextCount, 0)
    }

    func testTimeoutCleansUpWithoutAnyCallback() {
        let probe = CompletionProbe()
        let registry = DiskArbitrationCallbackRegistry(cleanupObserver: { probe.recordCleanup($0) })
        let context = registry.register(resume: { probe.record($0) }, cleanup: { probe.recordResourceCleanup() })

        registry.resolve(context: context, event: .timeout)

        XCTAssertEqual(probe.results, [.timedOut])
        XCTAssertEqual(probe.cleanedContextKeys, [UInt(bitPattern: context)])
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

        var newContexts: [UnsafeMutableRawPointer] = []
        for _ in 0..<1_000 {
            let context = registry.register { probe.record($0) }
            newContexts.append(context)
        }

        XCTAssertFalse(newContexts.contains { UInt(bitPattern: $0) == UInt(bitPattern: staleContext) })
        registry.resolveCallback(context: staleContext, result: .success)
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
            let contextKey = UInt(bitPattern: context)
            let ready = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()
            let contenders: [@Sendable () -> Void] = [
                { registry.resolveCallback(context: UnsafeMutableRawPointer(bitPattern: contextKey), result: .success) },
                { registry.resolve(context: UnsafeMutableRawPointer(bitPattern: contextKey), event: .timeout) },
                { registry.resolve(context: UnsafeMutableRawPointer(bitPattern: contextKey), event: .cancelled) }
            ]

            for contender in contenders {
                ready.enter()
                finished.enter()
                DispatchQueue.global().async {
                    ready.leave()
                    start.wait()
                    contender()
                    finished.leave()
                }
            }
            ready.wait()
            for _ in contenders { start.signal() }
            finished.wait()

            XCTAssertEqual(probe.results.count, 1)
            XCTAssertEqual(probe.resourceCleanupCount, 1)
            XCTAssertEqual(registry.registeredContextCount, 0)
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
        XCTAssertEqual(probe.cleanedContextKeys, [UInt(bitPattern: context)])
        XCTAssertEqual(registry.registeredContextCount, 0)
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

private final class CompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [DiskArbitrationOperationResult] = []
    private(set) var cleanedContextKeys: [UInt] = []
    private(set) var resourceCleanupCount = 0

    func record(_ result: DiskArbitrationOperationResult) {
        lock.withLock { results.append(result) }
    }

    func recordCleanup(_ key: UInt) {
        lock.withLock { cleanedContextKeys.append(key) }
    }

    func recordResourceCleanup() {
        lock.withLock { resourceCleanupCount += 1 }
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
