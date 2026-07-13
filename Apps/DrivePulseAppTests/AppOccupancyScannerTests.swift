import Foundation
import XCTest
@testable import DrivePulseApp

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
    private var mutableRequestedLimit: Int?
    private var mutableInspectedPIDs: [Int32] = []

    init(
        snapshots: [ProcessOccupancySnapshot],
        failingPIDs: Set<Int32> = []
    ) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        self.failingPIDs = failingPIDs
    }

    var requestedLimit: Int? { lock.withLock { mutableRequestedLimit } }
    var inspectedPIDs: [Int32] { lock.withLock { mutableInspectedPIDs } }

    func candidatePIDs(limit: Int) throws -> [Int32] {
        lock.withLock { mutableRequestedLimit = limit }
        return Array((Set(snapshots.keys).union(failingPIDs)).sorted().prefix(limit))
    }

    func inspect(pid: Int32) throws -> ProcessOccupancySnapshot {
        lock.withLock { mutableInspectedPIDs.append(pid) }
        if failingPIDs.contains(pid) { throw FixtureInspectionError.permissionDenied }
        guard let snapshot = snapshots[pid] else { throw FixtureInspectionError.permissionDenied }
        return snapshot
    }
}
