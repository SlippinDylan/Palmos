import Darwin
import Foundation
import XCTest
@testable import PalmosApp

final class AppOccupancyScannerTests: XCTestCase {
    func testRecognizesOpenPathsWorkingDirectoriesAndExactDeviceNodes() async throws {
        let snapshots = try loadFixture()
        let scanner = AppOccupancyScanner(inspector: FixtureProcessInspector(snapshots: snapshots))

        let result = await scanner.scan(scope: targetScope, deadline: .now.advanced(by: .seconds(1)))

        XCTAssertEqual(result.holders, [
            OccupancyHolder(pid: 501, executableName: "Finder", displayName: "Finder", type: .openFileOrDirectory),
            OccupancyHolder(pid: 502, executableName: "zsh", displayName: "Terminal", type: .workingDirectory),
            OccupancyHolder(pid: 503, executableName: "worker", displayName: nil, type: .deviceNode),
        ])
        XCTAssertTrue(result.isComplete)
    }

    func testExcludesMountAndDevicePrefixCollisions() async throws {
        let snapshots = try loadFixture()
        let scanner = AppOccupancyScanner(inspector: FixtureProcessInspector(snapshots: snapshots))

        let result = await scanner.scan(scope: targetScope, deadline: .now.advanced(by: .seconds(1)))

        XCTAssertFalse(result.holders.contains { $0.pid == 504 })
    }

    func testMarksScanIncompleteWhenAProcessCannotBeInspected() async {
        let inspector = FixtureProcessInspector(
            snapshots: [ProcessOccupancySnapshot(pid: 501, executableName: "Finder", displayName: "Finder", openPaths: ["/Volumes/Data/report.txt"], workingDirectory: nil, deviceNodes: [])],
            failingPIDs: [502]
        )
        let scanner = AppOccupancyScanner(inspector: inspector)

        let result = await scanner.scan(scope: targetScope, deadline: .now.advanced(by: .seconds(1)))

        XCTAssertEqual(result.holders.map(\.pid), [501])
        XCTAssertFalse(result.isComplete)
    }

    func testStopsAtDeadlineAndDiscardsUninspectedCandidates() async {
        let inspector = FixtureProcessInspector(
            snapshots: [ProcessOccupancySnapshot(pid: 501, executableName: "Finder", displayName: "Finder", openPaths: ["/Volumes/Data/report.txt"], workingDirectory: nil, deviceNodes: [])]
        )
        let scanner = AppOccupancyScanner(inspector: inspector)

        let result = await scanner.scan(scope: targetScope, deadline: expiredDeadline)

        XCTAssertTrue(result.holders.isEmpty)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(inspector.inspectedPIDs.isEmpty)
    }

    func testCapsCandidateEnumerationAt4096AndReturnedHoldersAt64() async {
        let snapshots = (1...100).map {
            ProcessOccupancySnapshot(pid: Int32($0), executableName: "worker\($0)", displayName: nil, openPaths: ["/Volumes/Data/file\($0)"], workingDirectory: nil, deviceNodes: [])
        }
        let inspector = FixtureProcessInspector(snapshots: snapshots)
        let scanner = AppOccupancyScanner(inspector: inspector)

        let result = await scanner.scan(scope: targetScope, deadline: .now.advanced(by: .seconds(1)))

        XCTAssertEqual(inspector.requestedLimit, 4_096)
        XCTAssertEqual(result.holders.count, 64)
        XCTAssertFalse(result.isComplete)
    }

    @MainActor
    func testInspectionRunsOffMainThread() async {
        let inspector = FixtureProcessInspector(
            snapshots: [ProcessOccupancySnapshot(pid: 501, executableName: "Finder", displayName: nil, openPaths: [], workingDirectory: nil, deviceNodes: [])]
        )

        _ = await AppOccupancyScanner(inspector: inspector).scan(
            scope: targetScope,
            deadline: .now.advanced(by: .seconds(1))
        )

        XCTAssertEqual(inspector.inspectionMainThreadStates, [false])
    }

    func testRetainsFDEvidenceWhenOtherProcessMetadataIsIncomplete() async {
        let snapshot = ProcessOccupancySnapshot(
            pid: 503,
            executableName: "worker",
            displayName: nil,
            openPaths: [],
            workingDirectory: nil,
            deviceNodes: ["/dev/rdisk4"],
            isComplete: false
        )

        let result = await AppOccupancyScanner(
            inspector: FixtureProcessInspector(snapshots: [snapshot])
        ).scan(scope: targetScope, deadline: .now.advanced(by: .seconds(1)))

        XCTAssertEqual(result.holders.map { $0.type }, [OccupancyType.deviceNode])
        XCTAssertFalse(result.isComplete)
    }

    func testDeduplicatesAndStablySortsHolders() async {
        let duplicate = ProcessOccupancySnapshot(
            pid: 502,
            executableName: "zsh",
            displayName: "Terminal",
            openPaths: ["/Volumes/Data/a", "/Volumes/Data/b"],
            workingDirectory: "/Volumes/Data",
            deviceNodes: []
        )
        let earlierPID = ProcessOccupancySnapshot(
            pid: 501,
            executableName: "Finder",
            displayName: nil,
            openPaths: ["/Volumes/Data/c"],
            workingDirectory: nil,
            deviceNodes: []
        )

        let result = await AppOccupancyScanner(
            inspector: FixtureProcessInspector(snapshots: [duplicate, earlierPID], candidatePIDs: [502, 502, 501])
        ).scan(scope: targetScope, deadline: .now.advanced(by: .seconds(1)))

        XCTAssertEqual(result.holders.map(\.pid), [501, 502, 502])
        XCTAssertEqual(result.holders.map { $0.type }, [
            OccupancyType.openFileOrDirectory,
            .openFileOrDirectory,
            .workingDirectory,
        ])
    }

    func testCancellationStopsBeforeAllCandidatesAreInspected() async {
        let snapshots = (1...100).map {
            ProcessOccupancySnapshot(pid: Int32($0), executableName: "p\($0)", displayName: nil, openPaths: [], workingDirectory: nil, deviceNodes: [])
        }
        let inspector = FixtureProcessInspector(snapshots: snapshots, inspectionDelay: 0.002)
        let scope = targetScope
        let task = Task {
            await AppOccupancyScanner(inspector: inspector).scan(
                scope: scope,
                deadline: .now.advanced(by: .seconds(2))
            )
        }

        try? await Task.sleep(for: .milliseconds(15))
        task.cancel()
        let result = await task.value

        XCTAssertFalse(result.isComplete)
        XCTAssertLessThan(inspector.inspectedPIDs.count, snapshots.count)
    }

    func testLivePathDecoderNeverReadsPastFixedBuffer() {
        XCTAssertEqual(LiveProcessInspector.decodePathBuffer([47, 100, 101, 118, 0, 120]), "/dev")
        XCTAssertEqual(LiveProcessInspector.decodePathBuffer([97, 98, 99]), "abc")
    }

    func testBoundedFDEnumeratorCapsReportedDescriptorsAndMarksIncomplete() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            limits: ProcessInspectionLimits(maxFileDescriptorsPerProcess: 2),
            query: { _, _, _ in Int32(stride * 3) }
        )

        XCTAssertEqual(result.descriptors.count, 2)
        XCTAssertFalse(result.isComplete)
    }

    func testBoundedFDEnumeratorRejectsNegativeAndMisalignedByteCounts() {
        let negative = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, _, _ in -1 }
        )
        let misaligned = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, _, _ in 1 }
        )

        XCTAssertTrue(negative.descriptors.isEmpty)
        XCTAssertFalse(negative.isComplete)
        XCTAssertTrue(misaligned.descriptors.isEmpty)
        XCTAssertFalse(misaligned.isComplete)
    }

    func testBoundedFDEnumeratorClampsFillCountToAllocatedBuffer() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            limits: ProcessInspectionLimits(maxFileDescriptorsPerProcess: 2),
            query: { _, buffer, byteCount in
                guard let buffer else { return Int32(stride * 2) }
                buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(byteCount))
                return Int32(stride * 3)
            }
        )

        XCTAssertEqual(result.descriptors.count, 2)
        XCTAssertFalse(result.isComplete)
    }

    func testBoundedFDEnumeratorPreservesAlignedPrefixFromMisalignedFill() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let payload = makeFDInfoData(fd: 11, type: 4)
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, buffer, _ in
                guard let buffer else { return Int32(stride * 2) }
                payload.withUnsafeBytes { raw in
                    guard let source = raw.baseAddress else { return }
                    buffer.copyMemory(from: source, byteCount: payload.count)
                }
                return Int32(stride + 1)
            }
        )

        XCTAssertEqual(result.descriptors, [ProcessFileDescriptor(number: 11, type: 4)])
        XCTAssertFalse(result.isComplete)
    }

    func testBoundedFDEnumeratorTreatsShrinkingFillAsComplete() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let payload = makeFDInfoData(fd: 3, type: 1) + makeFDInfoData(fd: 9, type: 2)
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, buffer, _ in
                guard let buffer else { return Int32(stride * 3) }
                payload.withUnsafeBytes { raw in
                    guard let source = raw.baseAddress else { return }
                    buffer.copyMemory(from: source, byteCount: payload.count)
                }
                return Int32(payload.count)
            }
        )

        XCTAssertEqual(result.descriptors.count, 2)
        XCTAssertTrue(result.isComplete)
    }

    func testBoundedFDEnumeratorRejectsNegativeFillCount() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, buffer, _ in buffer == nil ? Int32(stride) : -1 }
        )

        XCTAssertTrue(result.descriptors.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    func testBoundedFDEnumeratorRechecksContinuationAfterZeroSizeQuery() {
        let continuation = FDEnumerationContinuation()
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            while: { continuation.shouldContinue },
            query: { _, _, _ in
                continuation.stop()
                return 0
            }
        )

        XCTAssertTrue(result.descriptors.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    func testBoundedFDEnumeratorRechecksContinuationAfterFill() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let continuation = FDEnumerationContinuation()
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            while: { continuation.shouldContinue },
            query: { _, buffer, byteCount in
                guard let buffer else { return Int32(stride) }
                buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(byteCount))
                continuation.stop()
                return Int32(stride)
            }
        )

        XCTAssertTrue(result.descriptors.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    func testBoundedFDEnumeratorTreatsExactCapAsComplete() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            limits: ProcessInspectionLimits(maxFileDescriptorsPerProcess: 2),
            query: { _, buffer, byteCount in
                guard let buffer else { return Int32(stride * 2) }
                buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(byteCount))
                return Int32(stride * 2)
            }
        )

        XCTAssertEqual(result.descriptors.count, 2)
        XCTAssertTrue(result.isComplete)
    }

    func testBoundedFDEnumeratorPreservesSmallFilledDescriptorList() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let first = makeFDInfoData(fd: 3, type: 1)
        let second = makeFDInfoData(fd: 9, type: 2)
        let payload = first + second
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, buffer, byteCount in
                guard let buffer else { return Int32(payload.count) }
                payload.withUnsafeBytes { raw in
                    guard let source = raw.baseAddress else { return }
                    buffer.copyMemory(from: source, byteCount: min(Int(byteCount), payload.count))
                }
                return Int32(payload.count)
            }
        )

        XCTAssertEqual(result.descriptors, [
            ProcessFileDescriptor(number: 3, type: 1),
            ProcessFileDescriptor(number: 9, type: 2),
        ])
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(stride * result.descriptors.count, payload.count)
    }

    private var targetScope: OccupancyTargetScope {
        OccupancyTargetScope(
            physicalBSDName: "disk4",
            deviceNodes: ["/dev/disk4", "/dev/rdisk4"],
            mountURLs: [URL(fileURLWithPath: "/Volumes/Data")]
        )
    }

    private var expiredDeadline: ContinuousClock.Instant { .now.advanced(by: .milliseconds(-1)) }

    private func loadFixture() throws -> [ProcessOccupancySnapshot] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "process-fd-snapshot", withExtension: "json"))
        return try JSONDecoder().decode([ProcessOccupancySnapshot].self, from: Data(contentsOf: url))
    }
}

private enum FixtureInspectionError: Error { case permissionDenied }

private final class FixtureProcessInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [Int32: ProcessOccupancySnapshot]
    private let failingPIDs: Set<Int32>
    private let candidatePIDOverride: [Int32]?
    private let inspectionDelay: TimeInterval
    private var mutableRequestedLimit: Int?
    private var mutableInspectedPIDs: [Int32] = []
    private var mutableInspectionMainThreadStates: [Bool] = []

    init(
        snapshots: [ProcessOccupancySnapshot],
        failingPIDs: Set<Int32> = [],
        candidatePIDs: [Int32]? = nil,
        inspectionDelay: TimeInterval = 0
    ) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        self.failingPIDs = failingPIDs
        candidatePIDOverride = candidatePIDs
        self.inspectionDelay = inspectionDelay
    }

    var requestedLimit: Int? { lock.withLock { mutableRequestedLimit } }
    var inspectedPIDs: [Int32] { lock.withLock { mutableInspectedPIDs } }
    var inspectionMainThreadStates: [Bool] { lock.withLock { mutableInspectionMainThreadStates } }

    func candidatePIDs(limit: Int) throws -> [Int32] {
        lock.withLock { mutableRequestedLimit = limit }
        return Array((candidatePIDOverride ?? Set(snapshots.keys).union(failingPIDs).sorted()).prefix(limit))
    }

    func inspect(pid: Int32) throws -> ProcessOccupancySnapshot {
        if inspectionDelay > 0 { Thread.sleep(forTimeInterval: inspectionDelay) }
        lock.withLock {
            mutableInspectedPIDs.append(pid)
            mutableInspectionMainThreadStates.append(Thread.isMainThread)
        }
        if failingPIDs.contains(pid) { throw FixtureInspectionError.permissionDenied }
        guard let snapshot = snapshots[pid] else { throw FixtureInspectionError.permissionDenied }
        return snapshot
    }
}

private func makeFDInfoData(fd: Int32, type: UInt32) -> Data {
    var info = proc_fdinfo(proc_fd: fd, proc_fdtype: type)
    return withUnsafeBytes(of: &info) { Data($0) }
}

private final class FDEnumerationContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var isRunning = true

    var shouldContinue: Bool { lock.withLock { isRunning } }
    func stop() { lock.withLock { isRunning = false } }
}
