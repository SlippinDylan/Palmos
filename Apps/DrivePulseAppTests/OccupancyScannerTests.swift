import XCTest

@testable import DrivePulseApp

final class OccupancyScannerTests: XCTestCase {
    func testCancellationDuringAppScanReturnsEmptyIncompleteWithoutCallingHelper() async {
        let app = ControlledAppOccupancyScanner()
        let helper = RecordingHelperOccupancyScanner(result: .init(holders: [], isComplete: true))
        let scanner = OccupancyScanner(appScanner: app, helperScanner: helper)
        let scope = makeScope()
        let task = Task { await scanner.scan(workflowID: UUID(), scope: scope) }
        await app.waitUntilStarted()

        task.cancel()
        app.finish(with: .init(
            holders: [makeHolder(pid: 42, executableName: "Finder", type: .openFileOrDirectory)],
            isComplete: true
        ))
        let result = await task.value

        XCTAssertEqual(result, .init(holders: [], isComplete: false))
        let helperScanCount = await helper.scanCount
        XCTAssertEqual(helperScanCount, 0)
    }

    func testCancellationDuringHelperScanReturnsEmptyIncompletePromptly() async {
        let helper = SleepingHelperOccupancyScanner()
        let scanner = OccupancyScanner(
            appScanner: StubAppOccupancyScanner(result: .init(holders: [], isComplete: true)),
            helperScanner: helper
        )
        let scope = makeScope()
        let task = Task { await scanner.scan(workflowID: UUID(), scope: scope) }
        await helper.waitUntilStarted()

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result, .init(holders: [], isComplete: false))
        let scanCount = await helper.scanCount
        XCTAssertEqual(scanCount, 1)
    }

    func testActionableCompleteAppResultDoesNotCallHelper() async {
        let holder = makeHolder(pid: 42, executableName: "Finder", type: .openFileOrDirectory)
        let app = StubAppOccupancyScanner(result: .init(holders: [holder], isComplete: true))
        let helper = RecordingHelperOccupancyScanner(result: .init(holders: [], isComplete: true))
        let scanner = OccupancyScanner(appScanner: app, helperScanner: helper)

        let result = await scanner.scan(workflowID: UUID(), scope: makeScope())

        XCTAssertEqual(result, .init(holders: [holder], isComplete: true))
        let helperScanCount = await helper.scanCount
        XCTAssertEqual(helperScanCount, 0)
    }

    func testCompleteEmptyAppResultCallsHelperBecauseCallerAlreadyEstablishedBusy() async {
        let helperHolder = makeHolder(pid: 7, executableName: "backupd", type: .deviceNode)
        let helper = RecordingHelperOccupancyScanner(
            result: .init(holders: [helperHolder], isComplete: true)
        )
        let scanner = OccupancyScanner(
            appScanner: StubAppOccupancyScanner(result: .init(holders: [], isComplete: true)),
            helperScanner: helper
        )
        let workflowID = UUID()

        let result = await scanner.scan(workflowID: workflowID, scope: makeScope())

        XCTAssertEqual(result, .init(holders: [helperHolder], isComplete: true))
        let helperRequests = await helper.requests
        XCTAssertEqual(helperRequests, [.init(workflowID: workflowID, physicalBSDName: "disk4")])
    }

    func testCompleteUnknownAppHolderIsNotActionableAndCallsHelper() async {
        let unknown = makeHolder(pid: 4, executableName: "kernel_task", type: .unknown)
        let known = makeHolder(pid: 4, executableName: "kernel_task", type: .deviceNode)
        let helper = RecordingHelperOccupancyScanner(result: .init(holders: [known], isComplete: true))
        let scanner = OccupancyScanner(
            appScanner: StubAppOccupancyScanner(result: .init(holders: [unknown], isComplete: true)),
            helperScanner: helper
        )

        let result = await scanner.scan(workflowID: UUID(), scope: makeScope())

        XCTAssertEqual(result.holders, [known, unknown])
        let helperScanCount = await helper.scanCount
        XCTAssertEqual(helperScanCount, 1)
    }

    func testIncompleteAppResultCallsHelperAndMergesResults() async {
        let appHolder = makeHolder(pid: 3, executableName: "Terminal", type: .workingDirectory)
        let helperHolder = makeHolder(pid: 5, executableName: "sync", type: .openFileOrDirectory)
        let helper = RecordingHelperOccupancyScanner(
            result: .init(holders: [helperHolder], isComplete: true)
        )
        let scanner = OccupancyScanner(
            appScanner: StubAppOccupancyScanner(result: .init(holders: [appHolder], isComplete: false)),
            helperScanner: helper
        )

        let result = await scanner.scan(workflowID: UUID(), scope: makeScope())

        XCTAssertEqual(result.holders, [appHolder, helperHolder])
        XCTAssertTrue(result.isComplete)
        let helperScanCount = await helper.scanCount
        XCTAssertEqual(helperScanCount, 1)
    }

    func testUnavailableHelperPreservesAppEvidenceAndReportsIncomplete() async {
        let appHolder = makeHolder(pid: 8, executableName: "shell", type: .unknown)
        let scanner = OccupancyScanner(
            appScanner: StubAppOccupancyScanner(result: .init(holders: [appHolder], isComplete: false)),
            helperScanner: RecordingHelperOccupancyScanner(error: TestError.unavailable)
        )

        let result = await scanner.scan(workflowID: UUID(), scope: makeScope())

        XCTAssertEqual(result, .init(holders: [appHolder], isComplete: false))
    }

    func testMergeDeduplicatesByPIDAndTypePrefersDisplayNameSortsAndCapsAt64() async {
        let appDuplicate = makeHolder(
            pid: 9,
            executableName: "zeta",
            type: .deviceNode
        )
        let helperDuplicate = makeHolder(
            pid: 9,
            executableName: "helper-zeta",
            displayName: "Alpha App",
            type: .deviceNode
        )
        let helperHolders = [helperDuplicate] + (0..<70).map { index in
            makeHolder(
                pid: Int32(100 + index),
                executableName: String(format: "Process %02d", 69 - index),
                type: index.isMultiple(of: 2) ? .workingDirectory : .openFileOrDirectory
            )
        }
        let scanner = OccupancyScanner(
            appScanner: StubAppOccupancyScanner(
                result: .init(holders: [appDuplicate], isComplete: false)
            ),
            helperScanner: RecordingHelperOccupancyScanner(
                result: .init(holders: helperHolders, isComplete: true)
            )
        )

        let result = await scanner.scan(workflowID: UUID(), scope: makeScope())

        XCTAssertEqual(result.holders.count, 64)
        XCTAssertEqual(result.holders.first, helperDuplicate)
        XCTAssertEqual(result.holders.filter { $0.pid == 9 && $0.type == .deviceNode }.count, 1)
        XCTAssertEqual(result.holders.map(\.preferredName), result.holders.map(\.preferredName).sorted())
        XCTAssertFalse(result.isComplete)
    }

    func testStableSortBreaksPreferredNameTiesByPIDThenType() async {
        let holders = [
            makeHolder(pid: 2, executableName: "Same", type: .workingDirectory),
            makeHolder(pid: 1, executableName: "Same", type: .workingDirectory),
            makeHolder(pid: 1, executableName: "Same", type: .openFileOrDirectory)
        ]
        let scanner = OccupancyScanner(
            appScanner: StubAppOccupancyScanner(result: .init(holders: [], isComplete: true)),
            helperScanner: RecordingHelperOccupancyScanner(
                result: .init(holders: holders, isComplete: true)
            )
        )

        let result = await scanner.scan(workflowID: UUID(), scope: makeScope())

        XCTAssertEqual(result.holders, [holders[2], holders[1], holders[0]])
    }

    private func makeScope() -> OccupancyTargetScope {
        OccupancyTargetScope(
            physicalBSDName: "disk4",
            deviceNodes: ["/dev/disk4"],
            mountURLs: [URL(fileURLWithPath: "/Volumes/Data")]
        )
    }

    private func makeHolder(
        pid: Int32,
        executableName: String,
        displayName: String? = nil,
        type: OccupancyType
    ) -> OccupancyHolder {
        OccupancyHolder(
            pid: pid,
            executableName: executableName,
            displayName: displayName,
            type: type
        )
    }
}

private struct StubAppOccupancyScanner: AppOccupancyScanning {
    let result: OccupancyScanResult

    func scan(
        scope: OccupancyTargetScope,
        deadline: ContinuousClock.Instant
    ) async -> OccupancyScanResult {
        result
    }
}

private final class ControlledAppOccupancyScanner: AppOccupancyScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OccupancyScanResult, Never>?
    private var started = false

    func scan(
        scope: OccupancyTargetScope,
        deadline: ContinuousClock.Instant
    ) async -> OccupancyScanResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                started = true
                self.continuation = continuation
            }
        }
    }

    func waitUntilStarted() async {
        while lock.withLock({ started == false }) { await Task.yield() }
    }

    func finish(with result: OccupancyScanResult) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

private actor RecordingHelperOccupancyScanner: HelperOccupancyScanning {
    struct Request: Equatable {
        let workflowID: UUID
        let physicalBSDName: String
    }

    private(set) var requests: [Request] = []
    var scanCount: Int { requests.count }
    private let result: OccupancyScanResult?
    private let error: Error?

    init(result: OccupancyScanResult) {
        self.result = result
        error = nil
    }

    init(error: Error) {
        result = nil
        self.error = error
    }

    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult {
        requests.append(.init(workflowID: workflowID, physicalBSDName: physicalBSDName))
        if let error { throw error }
        return try XCTUnwrap(result)
    }
}

private actor SleepingHelperOccupancyScanner: HelperOccupancyScanning {
    private(set) var scanCount = 0

    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult {
        scanCount += 1
        try await Task.sleep(for: .seconds(60))
        return OccupancyScanResult(holders: [], isComplete: true)
    }

    func waitUntilStarted() async {
        while scanCount == 0 { await Task.yield() }
    }
}

private enum TestError: Error {
    case unavailable
}
