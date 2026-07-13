import Foundation
import XCTest

final class HelperOccupancySecurityTests: XCTestCase {
    func testValidatorRejectsMalformedWholeDiskNames() {
        for name in ["disk4s1", "/dev/disk4", "disk4;rm", ""] {
            XCTAssertThrowsError(try HelperOccupancyRequestValidator.validateBSDName(name))
        }
        XCTAssertNoThrow(try HelperOccupancyRequestValidator.validateBSDName("disk42"))
    }

    func testValidatorRejectsOversizedDataBeforeDecode() {
        XCTAssertThrowsError(
            try HelperOccupancyRequestValidator.validateRequestBytes(
                Data(repeating: 0, count: OccupancyXPCLimits.requestBytes + 1)
            )
        )
    }

    func testValidatorRejectsUnsafeCurrentMedia() async {
        let request = OccupancyScanRequest(workflowID: UUID(), physicalDeviceBSDName: "disk4")
        for media in [
            HelperDiskMedia(whole: false, external: true, ejectable: true),
            HelperDiskMedia(whole: true, external: false, ejectable: true),
            HelperDiskMedia(whole: true, external: true, ejectable: false),
        ] {
            let validator = HelperOccupancyRequestValidator(mediaLookup: { _ in media })
            await XCTAssertThrowsErrorAsync { try await validator.validate(request) }
        }
        let missing = HelperOccupancyRequestValidator(mediaLookup: { _ in nil })
        await XCTAssertThrowsErrorAsync { try await missing.validate(request) }
    }

    func testTopologyResolverUsesOnlyBSDNameAndRejectsReassignedTopology() async throws {
        let resolver = HelperDiskTopologyResolver(load: { name in
            XCTAssertEqual(name, "disk4")
            return HelperDiskTopology(
                physicalBSDName: "disk5",
                deviceNodes: ["/dev/disk5"],
                mountPaths: []
            )
        })
        await XCTAssertThrowsErrorAsync { try await resolver.resolve(wholeBSDName: "disk4") }
    }

    func testDifferentWorkflowIsBusyAndSameWorkflowSupersedesCooperatively() async throws {
        let inspector = BlockingHelperProcessInspector()
        let scanner = HelperOccupancyScanner(inspector: inspector)
        let scope = HelperOccupancyScope(deviceNodes: ["/dev/disk4"], mountPaths: [])
        let firstID = UUID()
        let first = Task { try await scanner.scan(workflowID: firstID, scope: scope) }
        await inspector.waitUntilStarted()

        await XCTAssertThrowsErrorAsync {
            try await scanner.scan(workflowID: UUID(), scope: scope)
        }

        let replacement = Task { try await scanner.scan(workflowID: firstID, scope: scope) }
        await inspector.waitUntilCancellationObserved()
        await inspector.release()
        let firstResult = try await first.value
        XCTAssertFalse(firstResult.isComplete)
        XCTAssertTrue(firstResult.holders.isEmpty)
        _ = try await replacement.value
        let observedCancellation = await inspector.observedCancellation
        XCTAssertTrue(observedCancellation)
    }

    func testScannerCapsCandidatesHoldersAndTimeout() async throws {
        let inspector = FixtureHelperProcessInspector(candidateCount: 5_000, holderPerPID: true)
        let scanner = HelperOccupancyScanner(inspector: inspector, timeout: .milliseconds(20))
        let result = try await scanner.scan(
            workflowID: UUID(),
            scope: HelperOccupancyScope(deviceNodes: ["/dev/disk4"], mountPaths: [])
        )
        let inspectedCount = await inspector.inspectedCount
        XCTAssertLessThanOrEqual(inspectedCount, OccupancyXPCLimits.maxCandidatePIDs)
        XCTAssertLessThanOrEqual(result.holders.count, OccupancyXPCLimits.maxHolders)
        XCTAssertFalse(result.isComplete)
    }

    func testResponseSchemaContainsNoSensitiveFields() throws {
        let response = OccupancyScanResponse(workflowID: UUID(), holders: [], isComplete: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: DrivePulseXPCMessages.encodeOccupancyResponse(response)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["workflowID", "holders", "isComplete"])
        let forbidden = ["path", "file", "command", "environment", "content"]
        XCTAssertFalse(object.keys.contains { key in forbidden.contains { key.localizedCaseInsensitiveContains($0) } })
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {}
    }
}

private actor BlockingHelperProcessInspector: HelperProcessInspecting {
    private var started = false
    private var released = false
    private var cancellationSeen = false

    var observedCancellation: Bool { cancellationSeen }

    func candidatePIDs(limit: Int) async throws -> [Int32] { [1] }
    func inspect(pid: Int32, scope: HelperOccupancyScope, shouldContinue: @escaping @Sendable () -> Bool) async throws -> HelperProcessSnapshot {
        started = true
        while !released {
            if !shouldContinue() {
                cancellationSeen = true
                return HelperProcessSnapshot(pid: pid, executableName: "test", displayName: nil, types: [], isComplete: false)
            }
            await Task.yield()
        }
        return HelperProcessSnapshot(pid: pid, executableName: "test", displayName: nil, types: [], isComplete: true)
    }
    func waitUntilStarted() async { while !started { await Task.yield() } }
    func waitUntilCancellationObserved() async { while !cancellationSeen { await Task.yield() } }
    func release() { released = true }
}

private actor FixtureHelperProcessInspector: HelperProcessInspecting {
    private let candidateCount: Int
    private let holderPerPID: Bool
    private var count = 0
    var inspectedCount: Int { count }

    init(candidateCount: Int, holderPerPID: Bool) {
        self.candidateCount = candidateCount
        self.holderPerPID = holderPerPID
    }
    func candidatePIDs(limit: Int) async throws -> [Int32] {
        (1...min(candidateCount, limit)).map(Int32.init)
    }
    func inspect(pid: Int32, scope: HelperOccupancyScope, shouldContinue: @escaping @Sendable () -> Bool) async throws -> HelperProcessSnapshot {
        count += 1
        return HelperProcessSnapshot(
            pid: pid,
            executableName: "process\(pid)",
            displayName: nil,
            types: holderPerPID ? ["deviceNode"] : [],
            isComplete: shouldContinue()
        )
    }
}
