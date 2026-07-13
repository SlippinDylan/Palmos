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
        await XCTAssertThrowsErrorAsync { _ = try await resolver.resolve(wholeBSDName: "disk4") }
    }

    func testLiveTopologyIncludesOnlyAPFSContainersBackedByTargetPhysicalDisk() async throws {
        let query = DiskutilFixtureQuery(responses: [
            ["list", "-plist", "disk4"]: [
                "AllDisksAndPartitions": [[
                    "DeviceIdentifier": "disk4",
                    "Partitions": [["DeviceIdentifier": "disk4s1"], ["DeviceIdentifier": "disk4s2"]],
                ]],
            ],
            ["info", "-plist", "disk4s1"]: ["APFSContainerReference": "disk8"],
            ["info", "-plist", "disk4s2"]: [:],
            ["apfs", "list", "-plist", "disk8"]: [
                "Containers": [
                    [
                        "ContainerReference": "disk8",
                        "PhysicalStores": [["DeviceIdentifier": "disk4s1"]],
                        "Volumes": [["DeviceIdentifier": "disk8s1", "MountPoint": "/Volumes/Target"]],
                    ],
                    [
                        "ContainerReference": "disk20",
                        "PhysicalStores": [["DeviceIdentifier": "disk99s1"]],
                        "Volumes": [["DeviceIdentifier": "disk20s1", "MountPoint": "/Volumes/Unrelated"]],
                    ],
                ],
            ],
        ])

        let topology = try await LiveHelperDiskTopologySource.topology("disk4", query: query.call)
        let resolved = try XCTUnwrap(topology)
        XCTAssertTrue(resolved.deviceNodes.contains("/dev/disk8"))
        XCTAssertTrue(resolved.deviceNodes.contains("/dev/disk8s1"))
        XCTAssertTrue(resolved.mountPaths.contains("/Volumes/Target"))
        XCTAssertFalse(resolved.deviceNodes.contains("/dev/disk20s1"))
        XCTAssertFalse(resolved.mountPaths.contains("/Volumes/Unrelated"))
        XCTAssertFalse(query.arguments.contains(["apfs", "list", "-plist", "disk4"]))
    }

    func testLiveTopologyExcludesUnrelatedAPFSNodesAndFailsClosedOnStaleStore() async throws {
        let query = DiskutilFixtureQuery(responses: [
            ["list", "-plist", "disk4"]: [
                "AllDisksAndPartitions": [["DeviceIdentifier": "disk4", "Partitions": [["DeviceIdentifier": "disk4s1"]]]],
            ],
            ["info", "-plist", "disk4s1"]: ["APFSContainerReference": "disk8"],
            ["apfs", "list", "-plist", "disk8"]: [
                "Containers": [[
                    "ContainerReference": "disk8",
                    "PhysicalStores": [["DeviceIdentifier": "disk99s1"]],
                    "Volumes": [["DeviceIdentifier": "disk8s1"], ["DeviceIdentifier": "disk20s1"]],
                ]],
            ],
        ])
        let topology = try await LiveHelperDiskTopologySource.topology("disk4", query: query.call)
        XCTAssertNil(topology)
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

    func testScannerDefensivelyCapsMisbehavingCandidateAdapter() async throws {
        let inspector = MisbehavingCandidateInspector()
        let scanner = HelperOccupancyScanner(inspector: inspector)
        let result = try await scanner.scan(
            workflowID: UUID(),
            scope: HelperOccupancyScope(deviceNodes: [], mountPaths: [])
        )
        let inspectedCount = await inspector.inspectedCountValue()
        XCTAssertEqual(inspectedCount, OccupancyXPCLimits.maxCandidatePIDs)
        XCTAssertFalse(result.isComplete)
    }

    func testScannerDiscardsPartialEvidenceWhenInspectReturnsAfterDeadline() async throws {
        let scanner = HelperOccupancyScanner(inspector: LateReturningInspector(), timeout: .milliseconds(5))
        let result = try await scanner.scan(
            workflowID: UUID(),
            scope: HelperOccupancyScope(deviceNodes: ["/dev/disk4"], mountPaths: [])
        )
        XCTAssertTrue(result.holders.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    func testResponseSchemaContainsNoSensitiveFields() throws {
        let response = OccupancyScanResponse(
            workflowID: UUID(),
            holders: [OccupancyHolderMessage(pid: 7, executableName: "tool", displayName: "Tool", type: "deviceNode")],
            isComplete: true
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: DrivePulseXPCMessages.encodeOccupancyResponse(response)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["workflowID", "holders", "isComplete"])
        let forbidden = ["path", "file", "command", "environment", "content"]
        XCTAssertFalse(object.keys.contains { key in forbidden.contains { key.localizedCaseInsensitiveContains($0) } })
        let holders = try XCTUnwrap(object["holders"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(holders.first).keys), ["pid", "executableName", "displayName", "type"])
    }

    func testEndpointRejectsOversizedBytesBeforeDecodeAndMapsBoundedError() async {
        let endpoint = HelperOccupancyEndpoint(
            validator: HelperOccupancyRequestValidator(mediaLookup: { _ in
                XCTFail("Oversized request must not reach validation")
                return nil
            }),
            resolver: HelperDiskTopologyResolver(load: { _ in nil }),
            scanner: HelperOccupancyScanner(inspector: FixtureHelperProcessInspector(candidateCount: 0, holderPerPID: false))
        )
        let result = await endpoint.handle(Data(repeating: 0, count: OccupancyXPCLimits.requestBytes + 1))
        XCTAssertNil(result.data)
        XCTAssertEqual(result.error?.domain, "com.drivepulse.smartservice.occupancy")
        XCTAssertEqual(result.error?.code, HelperOccupancyError.invalidRequest.rawValue)
        XCTAssertFalse(result.error?.localizedDescription.contains("/") == true)
    }

    func testEndpointEncodesBoundedOccupancyResponse() async throws {
        let workflowID = UUID()
        let endpoint = HelperOccupancyEndpoint(
            validator: HelperOccupancyRequestValidator(mediaLookup: { _ in
                HelperDiskMedia(whole: true, external: true, ejectable: true)
            }),
            resolver: HelperDiskTopologyResolver(load: { name in
                HelperDiskTopology(physicalBSDName: name, deviceNodes: ["/dev/\(name)"], mountPaths: [])
            }),
            scanner: HelperOccupancyScanner(inspector: FixtureHelperProcessInspector(candidateCount: 1, holderPerPID: true))
        )
        let request = try DrivePulseXPCMessages.encodeOccupancyRequest(
            OccupancyScanRequest(workflowID: workflowID, physicalDeviceBSDName: "disk4")
        )
        let result = await endpoint.handle(request)
        XCTAssertNil(result.error)
        let data = try XCTUnwrap(result.data)
        XCTAssertLessThanOrEqual(data.count, OccupancyXPCLimits.responseBytes)
        XCTAssertEqual(try DrivePulseXPCMessages.decodeOccupancyResponse(from: data).workflowID, workflowID)
    }

    func testClientAuthorizationRemainsAtXPCDelegateBoundary() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let delegateSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Apps/DrivePulseSMARTService/XPC/DrivePulseSMARTXPCDelegate.swift"),
            encoding: .utf8
        )
        let endpointSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Apps/DrivePulseSMARTService/Occupancy/HelperOccupancyEndpoint.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(delegateSource.contains("setCodeSigningRequirement"))
        XCTAssertFalse(endpointSource.contains("setCodeSigningRequirement"))
        XCTAssertFalse(endpointSource.contains("SMAuthorizedClients"))
    }
}

private final class DiskutilFixtureQuery: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [[String]: [String: Any]]
    private var calls: [[String]] = []
    var arguments: [[String]] { lock.withLock { calls } }
    init(responses: [[String]: [String: Any]]) { self.responses = responses }
    func call(_ arguments: [String]) throws -> [String: Any]? {
        lock.withLock { calls.append(arguments) }
        return responses[arguments]
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
        guard candidateCount > 0 else { return [] }
        return (1...min(candidateCount, limit)).map(Int32.init)
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

private actor MisbehavingCandidateInspector: HelperProcessInspecting {
    private var inspectedCount = 0
    func candidatePIDs(limit: Int) async throws -> [Int32] { (1...5_000).map(Int32.init) }
    func inspect(pid: Int32, scope: HelperOccupancyScope, shouldContinue: @escaping @Sendable () -> Bool) async throws -> HelperProcessSnapshot {
        inspectedCount += 1
        return HelperProcessSnapshot(pid: pid, executableName: "tool", displayName: nil, types: [], isComplete: true)
    }
    func inspectedCountValue() -> Int { inspectedCount }
}

private struct LateReturningInspector: HelperProcessInspecting {
    func candidatePIDs(limit: Int) async throws -> [Int32] { [1] }
    func inspect(pid: Int32, scope: HelperOccupancyScope, shouldContinue: @escaping @Sendable () -> Bool) async throws -> HelperProcessSnapshot {
        try await Task.sleep(for: .milliseconds(20))
        return HelperProcessSnapshot(pid: pid, executableName: "late", displayName: nil, types: ["deviceNode"], isComplete: true)
    }
}
