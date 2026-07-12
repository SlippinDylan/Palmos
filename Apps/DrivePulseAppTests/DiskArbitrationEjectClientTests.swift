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

    func testForceUnmountSuccessThenEjectFailureRemainsEjectingFailure() async {
        let adapter = StubDiskArbitrationOperating(results: [
            .success, .failure(status: DAReturn(kDAReturnNotReady), message: "not ready")
        ])
        let client = DiskArbitrationEjectClient(operations: adapter)

        let result = await client.performConfirmedForceEject(bsdName: "disk4")

        XCTAssertEqual(result.failure?.stage, .ejecting)
        XCTAssertEqual(result.failure?.category, .notReady)
    }

    func testCallbackWinningTimeoutCompletesAndReleasesContextExactlyOnce() async {
        await assertRace(first: .callback(.success), second: .timeout, expected: .success)
    }

    func testTimeoutWinningCallbackCompletesAndReleasesContextExactlyOnce() async {
        await assertRace(first: .timeout, second: .callback(.success), expected: .timedOut)
    }

    func testCancellationBeforeCallbackOrTimeoutCompletesAndReleasesContextExactlyOnce() async {
        await assertRace(first: .cancelled, second: .callback(.success), expected: .cancelled)
    }

    private func assertRace(
        first: DiskArbitrationOperationCompletion.Event,
        second: DiskArbitrationOperationCompletion.Event,
        expected: DiskArbitrationOperationResult
    ) async {
        let probe = CompletionProbe()
        let completion = DiskArbitrationOperationCompletion(
            resume: { result in probe.record(result) },
            releaseContext: { probe.releaseContext() }
        )

        completion.resolve(first)
        completion.resolve(second)
        completion.resolve(.timeout)
        completion.resolve(.cancelled)

        XCTAssertEqual(probe.results, [expected])
        XCTAssertEqual(probe.contextReleaseCount, 1)
    }
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
    private(set) var contextReleaseCount = 0

    func record(_ result: DiskArbitrationOperationResult) {
        lock.withLock { results.append(result) }
    }

    func releaseContext() {
        lock.withLock { contextReleaseCount += 1 }
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
