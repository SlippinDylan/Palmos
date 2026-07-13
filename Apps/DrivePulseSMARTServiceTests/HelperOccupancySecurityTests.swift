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
            _ = try await scanner.scan(workflowID: UUID(), scope: scope)
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
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: { _, _, _ in
                XCTFail("Oversized request must not reach validation")
                throw HelperOccupancyError.targetUnavailable
            }),
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
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: { name, _, _ in
                HelperOccupancyScope(deviceNodes: ["/dev/\(name)"], mountPaths: [])
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

    func testEndpointRejectsDifferentWorkflowBeforeSnapshot() async throws {
        let snapshot = ControlledSnapshotProvider()
        let endpoint = HelperOccupancyEndpoint(
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: snapshot.scope),
            scanner: HelperOccupancyScanner(inspector: FixtureHelperProcessInspector(candidateCount: 0, holderPerPID: false))
        )
        let firstID = UUID()
        let firstRequest = try occupancyRequest(firstID)
        let first = Task { await endpoint.handle(firstRequest) }
        await snapshot.waitUntilFirstStarted()
        let other = await endpoint.handle(try occupancyRequest(UUID()))
        XCTAssertEqual(other.error?.code, HelperOccupancyError.helperBusy.rawValue)
        let countAfterBusy = await snapshot.callCountValue()
        XCTAssertEqual(countAfterBusy, 1)
        await snapshot.releaseFirst()
        _ = await first.value
    }

    func testSameWorkflowNewGenerationCancelsWithoutStartingConcurrentWorker() async throws {
        let snapshot = ControlledSnapshotProvider()
        let endpoint = HelperOccupancyEndpoint(
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: snapshot.scope),
            scanner: HelperOccupancyScanner(inspector: FixtureHelperProcessInspector(candidateCount: 0, holderPerPID: false))
        )
        let workflowID = UUID()
        let request = try occupancyRequest(workflowID)
        let old = Task { await endpoint.handle(request) }
        await snapshot.waitUntilFirstStarted()
        let newResult = await endpoint.handle(request)
        XCTAssertFalse(
            try DrivePulseXPCMessages.decodeOccupancyResponse(from: XCTUnwrap(newResult.data)).isComplete
        )
        let oldResult = await old.value
        let oldResponse = try DrivePulseXPCMessages.decodeOccupancyResponse(from: XCTUnwrap(oldResult.data))
        XCTAssertFalse(oldResponse.isComplete)
        let finalCount = await snapshot.callCountValue()
        let maximumWorkers = await snapshot.maximumActiveWorkers()
        XCTAssertEqual(finalCount, 1)
        XCTAssertEqual(maximumWorkers, 1)
    }

    func testEndpointReturnsWithinFullDeadlineEvenWhenSnapshotWorkerIgnoresCancellation() async throws {
        let endpoint = HelperOccupancyEndpoint(
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: { _, _, _ in
                try await Task.sleep(for: .seconds(2))
                return HelperOccupancyScope(deviceNodes: [], mountPaths: [])
            }),
            scanner: HelperOccupancyScanner(inspector: FixtureHelperProcessInspector(candidateCount: 0, holderPerPID: false)),
            timeout: .milliseconds(50)
        )
        let clock = ContinuousClock()
        let start = clock.now
        let result = await endpoint.handle(try occupancyRequest(UUID()))
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(300))
        let response = try DrivePulseXPCMessages.decodeOccupancyResponse(from: XCTUnwrap(result.data))
        XCTAssertFalse(response.isComplete)
    }

    func testTopologyRunnerTerminatesHangingProcessAtDeadline() async throws {
        let runner = HelperTopologyCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
        let cancellation = HelperOperationCancellation()
        let clock = ContinuousClock()
        let start = clock.now
        await XCTAssertThrowsErrorAsync {
            _ = try await runner.run(
                arguments: ["10"],
                deadline: clock.now.advanced(by: .milliseconds(80)),
                cancellation: cancellation
            )
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testTopologyRunnerEscalatesToKillWhenChildIgnoresTerm() async throws {
        let runner = HelperTopologyCommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/perl"))
        let clock = ContinuousClock()
        let start = clock.now
        await XCTAssertThrowsErrorAsync {
            _ = try await runner.run(
                arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 10"],
                deadline: clock.now.advanced(by: .milliseconds(60)),
                cancellation: HelperOperationCancellation()
            )
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testTopologyRunnerDrainsLargePipesWithoutBackpressureHang() async throws {
        let runner = HelperTopologyCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
        let data = try await runner.run(
            arguments: ["-c", "head -c 3000000 /dev/zero; head -c 3000000 /dev/zero >&2"],
            deadline: ContinuousClock.now.advanced(by: .seconds(2)),
            cancellation: HelperOperationCancellation()
        )
        XCTAssertTrue(data.isEmpty)
    }

    func testSameWorkflowSupersedeTerminatesTopologyProcess() async throws {
        let snapshots = SupersedingProcessSnapshotProvider()
        let endpoint = HelperOccupancyEndpoint(
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: snapshots.scope),
            scanner: HelperOccupancyScanner(inspector: FixtureHelperProcessInspector(candidateCount: 0, holderPerPID: false))
        )
        let workflowID = UUID()
        let request = try occupancyRequest(workflowID)
        let old = Task { await endpoint.handle(request) }
        await snapshots.waitUntilFirstStarted()
        let clock = ContinuousClock()
        let start = clock.now
        let newer = await endpoint.handle(try occupancyRequest(workflowID))
        _ = await old.value
        XCTAssertNil(newer.error)
        XCTAssertFalse(
            try DrivePulseXPCMessages.decodeOccupancyResponse(from: XCTUnwrap(newer.data)).isComplete
        )
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testDeadlineReplyKeepsSlotOwnedUntilNoncooperativeWorkerActuallyExits() async throws {
        let snapshots = NoncooperativeSnapshotProvider()
        let endpoint = HelperOccupancyEndpoint(
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: snapshots.scope),
            scanner: HelperOccupancyScanner(inspector: FixtureHelperProcessInspector(candidateCount: 0, holderPerPID: false)),
            timeout: .milliseconds(40)
        )
        let workflowID = UUID()
        let request = try occupancyRequest(workflowID)
        let clock = ContinuousClock()
        let start = clock.now
        let first = await endpoint.handle(request)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(250))
        XCTAssertFalse(try DrivePulseXPCMessages.decodeOccupancyResponse(from: XCTUnwrap(first.data)).isComplete)

        for _ in 0..<5 {
            let repeated = await endpoint.handle(request)
            XCTAssertFalse(try DrivePulseXPCMessages.decodeOccupancyResponse(from: XCTUnwrap(repeated.data)).isComplete)
        }
        let other = await endpoint.handle(try occupancyRequest(UUID()))
        XCTAssertEqual(other.error?.code, HelperOccupancyError.helperBusy.rawValue)
        let callsWhileDraining = await snapshots.callCountValue()
        let maximumWorkers = await snapshots.maximumActiveWorkers()
        XCTAssertEqual(callsWhileDraining, 1)
        XCTAssertEqual(maximumWorkers, 1)

        await snapshots.release()
        await snapshots.waitUntilExited()
        try await Task.sleep(for: .milliseconds(20))
        let afterDrain = await endpoint.handle(request)
        XCTAssertNil(afterDrain.error)
        let callsAfterDrain = await snapshots.callCountValue()
        XCTAssertEqual(callsAfterDrain, 2)
    }

    func testAuthoritativeSnapshotFailsClosedWhenRegistryIdentityDrifts() async throws {
        let identities = RegistryIdentitySequence([10, 11])
        let inspector = FixtureHelperProcessInspector(candidateCount: 1, holderPerPID: true)
        let provider = HelperAuthoritativeSnapshotProvider.validating(
            registryIdentity: { _ in await identities.next() },
            media: { _ in HelperDiskMedia(whole: true, external: true, ejectable: true) },
            topology: { name, _, _ in
                HelperDiskTopology(physicalBSDName: name, deviceNodes: ["/dev/\(name)"], mountPaths: [])
            }
        )
        let endpoint = HelperOccupancyEndpoint(
            snapshotProvider: provider,
            scanner: HelperOccupancyScanner(inspector: inspector)
        )
        let result = await endpoint.handle(try occupancyRequest(UUID()))
        XCTAssertEqual(result.error?.code, HelperOccupancyError.unsafeTarget.rawValue)
        let inspectedCount = await inspector.inspectedCount
        XCTAssertEqual(inspectedCount, 0)
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

private func occupancyRequest(_ workflowID: UUID, disk: String = "disk4") throws -> Data {
    try DrivePulseXPCMessages.encodeOccupancyRequest(
        OccupancyScanRequest(workflowID: workflowID, physicalDeviceBSDName: disk)
    )
}

private actor ControlledSnapshotProvider {
    private var calls = 0
    private var firstStarted = false
    private var firstReleased = false
    private var activeWorkers = 0
    private var maximumWorkers = 0
    func scope(_ name: String, _ deadline: ContinuousClock.Instant, _ cancellation: HelperOperationCancellation) async throws -> HelperOccupancyScope {
        calls += 1
        activeWorkers += 1
        maximumWorkers = max(maximumWorkers, activeWorkers)
        defer { activeWorkers -= 1 }
        if calls == 1 {
            firstStarted = true
            while !cancellation.isCancelled && !firstReleased { await Task.yield() }
            if cancellation.isCancelled { throw CancellationError() }
            return HelperOccupancyScope(deviceNodes: ["/dev/\(name)"], mountPaths: [])
        }
        return HelperOccupancyScope(deviceNodes: ["/dev/\(name)"], mountPaths: [])
    }
    func waitUntilFirstStarted() async { while !firstStarted { await Task.yield() } }
    func releaseFirst() { firstReleased = true }
    func callCountValue() -> Int { calls }
    func maximumActiveWorkers() -> Int { maximumWorkers }
}

private actor RegistryIdentitySequence {
    private var values: [UInt64]
    init(_ values: [UInt64]) { self.values = values }
    func next() -> UInt64? { values.isEmpty ? nil : values.removeFirst() }
}

private actor SupersedingProcessSnapshotProvider {
    private var calls = 0
    private var firstStarted = false
    private let runner = HelperTopologyCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
    func scope(_ name: String, _ deadline: ContinuousClock.Instant, _ cancellation: HelperOperationCancellation) async throws -> HelperOccupancyScope {
        calls += 1
        if calls == 1 {
            firstStarted = true
            _ = try await runner.run(arguments: ["10"], deadline: deadline, cancellation: cancellation)
        }
        return HelperOccupancyScope(deviceNodes: ["/dev/\(name)"], mountPaths: [])
    }
    func waitUntilFirstStarted() async { while !firstStarted { await Task.yield() } }
}

private actor NoncooperativeSnapshotProvider {
    private var calls = 0
    private var activeWorkers = 0
    private var maximumWorkers = 0
    private var released = false
    private var exited = false
    func scope(_ name: String, _ deadline: ContinuousClock.Instant, _ cancellation: HelperOperationCancellation) async throws -> HelperOccupancyScope {
        calls += 1
        activeWorkers += 1
        maximumWorkers = max(maximumWorkers, activeWorkers)
        while !released { await Task.yield() }
        activeWorkers -= 1
        exited = true
        return HelperOccupancyScope(deviceNodes: ["/dev/\(name)"], mountPaths: [])
    }
    func release() { released = true }
    func waitUntilExited() async { while !exited { await Task.yield() } }
    func callCountValue() -> Int { calls }
    func maximumActiveWorkers() -> Int { maximumWorkers }
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
