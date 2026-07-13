import XCTest

import DrivePulseCore

@testable import DrivePulseApp

final class DeviceIOQuiescerTests: XCTestCase {
    func testLegacySMARTSelectorRemainsByteForByteStable() {
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.readSMARTData(for:withReply:))),
            "readSMARTDataFor:withReply:"
        )
        XCTAssertEqual(XPCContractVersion.currentMinor, XPCContractVersion.completionAwareSMARTMinor)
        let rawJSON = Data(#"{"device":{"name":"/dev/disk4"},"bytes":[0,255]}"#.utf8)
        XCTAssertEqual(DrivePulseXPCMessages.legacySMARTReply(payload: rawJSON), rawJSON)
    }

    func testMinorFourNegotiatesCompletionSMARTAndOccupancyTogether() {
        XCTAssertEqual(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 3),
            XPCFeatureCapabilities(completionAwareSMART: false, occupancyScanning: false)
        )
        XCTAssertEqual(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 4),
            XPCFeatureCapabilities(completionAwareSMART: true, occupancyScanning: true)
        )
    }

    func testOldAndNewAppHelperCompatibilityMatrix() {
        XCTAssertEqual(
            XPCCompatibilityPolicy.evaluate(appMajor: 1, appMinor: 3, helperMajor: 1, helperMinor: 3),
            .compatible
        ) // old app -> old helper
        XCTAssertEqual(
            XPCCompatibilityPolicy.evaluate(appMajor: 1, appMinor: 3, helperMajor: 1, helperMinor: 4),
            .compatible
        ) // old app -> new helper keeps legacy selector
        XCTAssertEqual(
            XPCCompatibilityPolicy.evaluate(appMajor: 1, appMinor: 4, helperMajor: 1, helperMinor: 3),
            .degraded
        ) // new app -> old helper
        XCTAssertEqual(
            XPCCompatibilityPolicy.evaluate(appMajor: 1, appMinor: 4, helperMajor: 1, helperMinor: 4),
            .compatible
        ) // new app -> new helper
    }

    func testBarrierDrainsTargetAndRejectsOnlyNewTargetWork() async throws {
        let tracker = DeviceIOTracker()
        let quiescer = DeviceIOQuiescer(tracker: tracker)
        let target = makeTarget("disk4")
        let existing = try await tracker.beginTargetOperation(physicalBSDName: "disk4", kind: .smart)

        let barrier = try await quiescer.acquireBarrier(for: target, timeout: .seconds(1))
        let readiness = Task { try await barrier.waitUntilReady() }

        do {
            _ = try await tracker.beginTargetOperation(physicalBSDName: "disk4", kind: .metadata)
            XCTFail("Target work must be paused while its barrier is held")
        } catch {
            XCTAssertEqual(error as? DeviceIOTracker.RegistrationError, .paused)
        }
        let unrelated = try await tracker.beginTargetOperation(physicalBSDName: "disk5", kind: .diskutil)
        await tracker.finish(unrelated)
        await tracker.finish(existing)
        try await readiness.value

        await barrier.release()
        let resumed = try await tracker.beginTargetOperation(physicalBSDName: "disk4", kind: .capacity)
        await tracker.finish(resumed)
    }

    func testGlobalOperationDrainsAndLaunchesResumeAfterRelease() async throws {
        let tracker = DeviceIOTracker()
        let global = try await tracker.beginGlobalOperation(kind: .systemProfiler)
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .seconds(1)
        )
        let readiness = Task { try await barrier.waitUntilReady() }

        do {
            _ = try await tracker.beginGlobalOperation(kind: .systemProfiler)
            XCTFail("Global launches must pause during preparation")
        } catch {
            XCTAssertEqual(error as? DeviceIOTracker.RegistrationError, .paused)
        }
        await tracker.finish(global)
        try await readiness.value
        await barrier.release()

        let resumed = try await tracker.beginGlobalOperation(kind: .systemProfiler)
        await tracker.finish(resumed)
    }

    func testBarrierTimesOutWhileTargetWorkRemainsInFlight() async throws {
        let tracker = DeviceIOTracker()
        let token = try await tracker.beginTargetOperation(physicalBSDName: "disk4", kind: .smart)
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(20)
        )

        do {
            try await barrier.waitUntilReady()
            XCTFail("Preparation must fail closed")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .timedOut)
        }
        await tracker.finish(token)
        await barrier.release()
    }

    func testCompletionResponseRejectsMalformedUnsupportedAndUnexitedReplies() throws {
        XCTAssertThrowsError(try DrivePulseXPCMessages.decodeSMARTReadCompletionResponse(from: Data("{}".utf8)))

        let unsupported = SMARTReadCompletionResponse(schemaVersion: 2, payload: Data(), processDidExit: true)
        XCTAssertThrowsError(try DrivePulseXPCMessages.decodeSMARTReadCompletionResponse(
            from: DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(unsupported)
        ))

        let unexited = SMARTReadCompletionResponse(schemaVersion: 1, payload: Data("{}".utf8), processDidExit: false)
        XCTAssertThrowsError(try DrivePulseXPCMessages.decodeAcknowledgedSMARTReadCompletionResponse(
            from: DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(unexited)
        ))
    }

    func testCompletionResponseRoundTripsSchemaOne() throws {
        let response = SMARTReadCompletionResponse(
            schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
            payload: Data("{\"ok\":true}".utf8),
            processDidExit: true
        )
        let data = try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(response)
        XCTAssertEqual(try DrivePulseXPCMessages.decodeAcknowledgedSMARTReadCompletionResponse(from: data), response)
    }

    func testMalformedSMARTCompletionKeepsPreparationUnsafe() async throws {
        let tracker = DeviceIOTracker()
        let handshake = try DrivePulseXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in Data() },
            readSMARTDataWithCompletion: { _ in Data("{}".utf8) },
            deviceIOTracker: tracker
        )

        _ = await client.refreshSMART(for: makeDevice("disk4"))
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(20)
        )
        do {
            try await barrier.waitUntilReady()
            XCTFail("Malformed completion must keep eject preparation unsafe")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .timedOut)
        }
        await barrier.release()
    }

    func testSMARTCancellationKeepsTokenUntilAcknowledgedReplyThenReleasesExactlyOnce() async throws {
        let tracker = DeviceIOTracker()
        let replyGate = AsyncSuspensionGate()
        let handshake = try DrivePulseXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let response = try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(.init(
            schemaVersion: 1,
            payload: Data("{}".utf8),
            processDidExit: true
        ))
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in Data() },
            readSMARTDataWithCompletion: { _ in await replyGate.wait(); return response },
            deviceIOTracker: tracker
        )
        let device = makeDevice("disk4")
        let refresh = Task { await client.refreshSMART(for: device) }
        while await replyGate.waiterCount == 0 { await Task.yield() }
        refresh.cancel()

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(20)
        )
        do {
            try await barrier.waitUntilReady()
            XCTFail("Cancellation cannot imply helper process exit")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .timedOut)
        }
        await replyGate.releaseAll()
        _ = await refresh.value
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testXPCReplyGateAcceptsOnlyFirstTerminalEvent() async throws {
        let result = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            let gate = XPCReplyGate(continuation: continuation)
            gate.resume(returning: Data("reply".utf8))
            gate.resume(throwing: NSError(domain: "late interruption", code: 1))
            gate.resume(returning: Data("duplicate reply".utf8))
        }
        XCTAssertEqual(result, Data("reply".utf8))
    }

    func testXPCInterruptionKeepsSMARTTokenUnsafe() async throws {
        try await assertSessionFailureKeepsSMARTUnsafe(event: .interrupted)
    }

    func testXPCInvalidationKeepsSMARTTokenUnsafe() async throws {
        try await assertSessionFailureKeepsSMARTUnsafe(event: .invalidated)
    }

    func testXPCNormalAcknowledgementReleasesSMARTTokenExactlyOnce() async throws {
        let tracker = DeviceIOTracker()
        let session = ControlledSMARTXPCSession()
        let client = try makeSessionClient(tracker: tracker, session: session)
        let device = makeDevice("disk4")
        let refresh = Task { await client.refreshSMART(for: device) }
        await session.waitUntilHandlerInstalled()
        let response = try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(.init(
            schemaVersion: 1, payload: Data("{}".utf8), processDidExit: true
        ))
        session.emit(.reply(response))
        session.emit(.reply(response))
        session.emit(.invalidated)
        _ = await refresh.value

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(100)
        )
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    @MainActor
    func testProductionProvidersAcceptOneSharedTracker() {
        let tracker = DeviceIOTracker()
        XCTAssertTrue(SMARTServiceClient(deviceIOTracker: tracker).usesDeviceIOTracker(tracker))
        XCTAssertTrue(LiveSystemProfilerProvider(deviceIOTracker: tracker).usesDeviceIOTracker(tracker))
        XCTAssertTrue(LiveDiskUtilAPFSProvider(deviceIOTracker: tracker).usesDeviceIOTracker(tracker))
        XCTAssertTrue(VolumeCapacityRefresher(deviceIOTracker: tracker).usesDeviceIOTracker(tracker))
    }

    @MainActor
    func testCapacityRejectsUnmappedAndResumesMappedResourceValuesAfterBarrierRelease() async throws {
        let tracker = DeviceIOTracker()
        let reads = LockedCounter()
        let refresher = VolumeCapacityRefresher(
            deviceIOTracker: tracker,
            capacityReader: { bsdName, _ in
                reads.increment()
                return .init(bsdName: bsdName, totalBytes: 10, availableBytes: 4, consumedBytes: 6)
            }
        )
        refresher.start(mountPoints: ["disk4s1": "/Volumes/Test"])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reads.value, 0)

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .seconds(1)
        )
        refresher.start(
            mountPoints: ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reads.value, 0)
        await barrier.release()

        let update = expectation(description: "capacity resumed")
        refresher.onUpdate = { _ in update.fulfill() }
        refresher.start(
            mountPoints: ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        await fulfillment(of: [update], timeout: 1)
        XCTAssertEqual(reads.value, 1)

        let drained = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(100)
        )
        try await drained.waitUntilReady()
        await drained.release()
        refresher.stop()
    }

    func testDiskutilAPFSListPausesOnlyWhenRelevantTargetIsBlocked() async throws {
        let tracker = DeviceIOTracker()
        let calls = LockedCounter()
        let arguments = LockedArray<[String]>()
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["APFSContainers": []],
            format: .xml,
            options: 0
        )
        let provider = LiveDiskUtilAPFSProvider(
            commandRunner: { _, commandArguments in
                calls.increment()
                arguments.append(commandArguments)
                return plist
            },
            deviceIOTracker: tracker
        )
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .seconds(1)
        )
        await provider.refresh(physicalBSDNames: ["disk4"])
        XCTAssertEqual(calls.value, 0)
        await provider.refresh(physicalBSDNames: ["disk5"])
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(arguments.values, [["apfs", "list", "-plist", "disk5"]])
        await barrier.release()
        await provider.refresh(physicalBSDNames: ["disk4"])
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(arguments.values.last, ["apfs", "list", "-plist", "disk4"])

        let drained = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(100)
        )
        try await drained.waitUntilReady()
        await drained.release()
    }

    func testDiskutilAPFSListDrainsEveryKnownTargetTokenDeterministically() async throws {
        let tracker = DeviceIOTracker()
        let gate = AsyncSuspensionGate()
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["APFSContainers": []], format: .xml, options: 0
        )
        let provider = LiveDiskUtilAPFSProvider(
            commandRunner: { _, _ in await gate.wait(); return plist },
            deviceIOTracker: tracker
        )
        let refresh = Task {
            await provider.refresh(physicalBSDNames: ["disk4"])
        }
        while await gate.waiterCount == 0 { await Task.yield() }

        let disk4Barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(20)
        )
        do { try await disk4Barrier.waitUntilReady(); XCTFail("Known target token must drain") }
        catch { XCTAssertEqual(error as? DeviceIOQuiescenceError, .timedOut) }
        await gate.releaseAll()
        await refresh.value
        try await disk4Barrier.waitUntilReady()
        await disk4Barrier.release()
    }

    func testDiskutilAPFSListMergesAndDeduplicatesPerTargetTopologyDeterministically() async throws {
        let arguments = LockedArray<[String]>()
        let provider = LiveDiskUtilAPFSProvider(commandRunner: { _, commandArguments in
            arguments.append(commandArguments)
            let physicalBSDName = commandArguments.last
            let containers: [[String: Any]]
            if physicalBSDName == "disk4" {
                containers = [
                    ["ContainerReference": "disk10", "CapacityCeiling": 100, "Volumes": []]
                ]
            } else {
                containers = [
                    ["ContainerReference": "disk10", "CapacityCeiling": 999, "Volumes": []],
                    ["ContainerReference": "disk11", "CapacityCeiling": 200, "Volumes": []]
                ]
            }
            return try? PropertyListSerialization.data(
                fromPropertyList: ["Containers": containers], format: .xml, options: 0
            )
        })

        await provider.refresh(physicalBSDNames: ["disk5", "disk4"])

        XCTAssertEqual(arguments.values, [
            ["apfs", "list", "-plist", "disk4"],
            ["apfs", "list", "-plist", "disk5"]
        ])
        let disk10 = await provider.containerInfo(forContainerBSDName: "disk10")
        let disk11 = await provider.containerInfo(forContainerBSDName: "disk11")
        XCTAssertEqual(disk10?.totalCapacityBytes, 100)
        XCTAssertEqual(disk11?.totalCapacityBytes, 200)
    }

    func testEverySystemProfilerSpawnIsGloballyDrained() async throws {
        let tracker = DeviceIOTracker()
        let gate = AsyncSuspensionGate()
        let provider = LiveSystemProfilerProvider(
            dataTypeRunner: { dataType in
                await gate.wait()
                return Data("{\"\(dataType)\":[]}".utf8)
            },
            deviceIOTracker: tracker
        )
        let refresh = Task { await provider.refresh() }
        while await gate.waiterCount < 3 { await Task.yield() }
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(20)
        )
        do {
            try await barrier.waitUntilReady()
            XCTFail("All spawned system_profiler processes must drain")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .timedOut)
        }
        await gate.releaseAll()
        await refresh.value
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testSubprocessCancellationTerminatesAndWaitsForProcessExit() async {
        let start = ContinuousClock.now
        let task = Task {
            await SubprocessRunner.run(
                executable: "/bin/sleep",
                arguments: ["10"]
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    private func makeTarget(_ bsdName: String) -> EjectWorkflowTarget {
        EjectWorkflowTarget(
            deviceID: DeviceID(rawValue: bsdName),
            physicalBSDName: bsdName,
            mediaRegistryEntryID: 1,
            displayName: bsdName,
            topologyGeneration: 1
        )
    }

    private func makeDevice(_ bsdName: String) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: bsdName),
            displayName: bsdName,
            transportName: "USB",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(historyLimit: 0),
            physicalStoreBSDName: bsdName,
            apfsContainerBSDName: nil,
            volumes: []
        )
    }

    private func assertSessionFailureKeepsSMARTUnsafe(event: SMARTXPCSessionEvent) async throws {
        let tracker = DeviceIOTracker()
        let session = ControlledSMARTXPCSession()
        let client = try makeSessionClient(tracker: tracker, session: session)
        let device = makeDevice("disk4")
        let refresh = Task { await client.refreshSMART(for: device) }
        await session.waitUntilHandlerInstalled()
        session.emit(event)
        _ = await refresh.value

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(20)
        )
        do { try await barrier.waitUntilReady(); XCTFail("Unacknowledged exit must remain unsafe") }
        catch { XCTAssertEqual(error as? DeviceIOQuiescenceError, .timedOut) }
        await barrier.release()
    }

    private func makeSessionClient(
        tracker: DeviceIOTracker,
        session: ControlledSMARTXPCSession
    ) throws -> SMARTServiceClient {
        let handshake = try DrivePulseXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        return SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in Data() },
            completionSession: session,
            deviceIOTracker: tracker
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedArray<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    var values: [Element] { lock.withLock { storage } }
    func append(_ element: Element) { lock.withLock { storage.append(element) } }
}

private actor AsyncSuspensionGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiterCount: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class ControlledSMARTXPCSession: SMARTCompletionXPCSession, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (SMARTXPCSessionEvent) -> Void)?

    func readSMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        lock.withLock { handler = eventHandler }
    }

    func waitUntilHandlerInstalled() async {
        while lock.withLock({ handler == nil }) { await Task.yield() }
    }

    func emit(_ event: SMARTXPCSessionEvent) {
        lock.withLock { handler }?(event)
    }
}
