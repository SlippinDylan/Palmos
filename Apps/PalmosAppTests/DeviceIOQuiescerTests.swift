import Darwin
import XCTest

import PalmosCore

@testable import PalmosApp

final class DeviceIOQuiescerTests: XCTestCase {
    func testLegacySMARTSelectorRemainsByteForByteStable() {
        XCTAssertEqual(
            NSStringFromSelector(#selector(PalmosSMARTXPCProtocol.readSMARTData(for:withReply:))),
            "readSMARTDataFor:withReply:"
        )
        XCTAssertGreaterThanOrEqual(
            XPCContractVersion.currentMinor,
            XPCContractVersion.smartCancellationMinor
        )
        let rawJSON = Data(#"{"device":{"name":"/dev/disk4"},"bytes":[0,255]}"#.utf8)
        XCTAssertEqual(PalmosXPCMessages.legacySMARTReply(payload: rawJSON), rawJSON)
    }

    func testMinorFourNegotiatesCompletionSMARTAndOccupancyTogether() {
        XCTAssertEqual(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 3),
            XPCFeatureCapabilities(
                completionAwareSMART: false,
                smartCancellation: false,
                observableSMARTFailures: false,
                occupancyScanning: false
            )
        )
        XCTAssertEqual(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 4),
            XPCFeatureCapabilities(
                completionAwareSMART: true,
                smartCancellation: false,
                observableSMARTFailures: false,
                occupancyScanning: true
            )
        )
        XCTAssertEqual(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 5),
            XPCFeatureCapabilities(
                completionAwareSMART: true,
                smartCancellation: false,
                observableSMARTFailures: false,
                occupancyScanning: true
            )
        )
        XCTAssertEqual(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 6),
            XPCFeatureCapabilities(
                completionAwareSMART: true,
                smartCancellation: true,
                observableSMARTFailures: true,
                occupancyScanning: true
            )
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
        XCTAssertEqual(
            XPCCompatibilityPolicy.evaluate(appMajor: 1, appMinor: 5, helperMajor: 1, helperMinor: 4),
            .degraded
        ) // cancellation-capable app -> completion-only helper
        XCTAssertEqual(
            XPCCompatibilityPolicy.evaluate(appMajor: 1, appMinor: 5, helperMajor: 1, helperMinor: 5),
            .compatible
        ) // cancellation-capable app -> matching helper
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

    func testTargetBarrierDoesNotWaitForOrPauseGlobalSystemProfilerWork() async throws {
        let tracker = DeviceIOTracker()
        let global = try await tracker.beginGlobalOperation(kind: .systemProfiler)
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .seconds(1)
        )
        try await barrier.waitUntilReady()
        let concurrentGlobal = try await tracker.beginGlobalOperation(kind: .systemProfiler)
        await tracker.finish(concurrentGlobal)
        await barrier.release()
        await tracker.finish(global)
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
        XCTAssertThrowsError(try PalmosXPCMessages.decodeSMARTReadCompletionResponse(from: Data("{}".utf8)))

        let unsupported = SMARTReadCompletionResponse(schemaVersion: 2, payload: Data(), processDidExit: true)
        XCTAssertThrowsError(try PalmosXPCMessages.decodeSMARTReadCompletionResponse(
            from: PalmosXPCMessages.encodeSMARTReadCompletionResponse(unsupported)
        ))

        let unexited = SMARTReadCompletionResponse(schemaVersion: 1, payload: Data("{}".utf8), processDidExit: false)
        XCTAssertThrowsError(try PalmosXPCMessages.decodeAcknowledgedSMARTReadCompletionResponse(
            from: PalmosXPCMessages.encodeSMARTReadCompletionResponse(unexited)
        ))
    }

    func testCompletionResponseRoundTripsSchemaOne() throws {
        let response = SMARTReadCompletionResponse(
            schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
            payload: Data("{\"ok\":true}".utf8),
            processDidExit: true
        )
        let data = try PalmosXPCMessages.encodeSMARTReadCompletionResponse(response)
        XCTAssertEqual(try PalmosXPCMessages.decodeAcknowledgedSMARTReadCompletionResponse(from: data), response)
    }

    func testMalformedSMARTCompletionBecomesExplicitSafetyBlock() async throws {
        let tracker = DeviceIOTracker()
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
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
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .legacySMARTCompletionUnobservable)
        }
        await barrier.release()

        let retryBarrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .seconds(1)
        )
        do {
            try await retryBarrier.waitUntilReady()
            XCTFail("Unobservable SMART completion must remain fail-closed")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .legacySMARTCompletionUnobservable)
        }
        await retryBarrier.release()
    }

    func testUnobservableSMARTCompletionDoesNotBlockReplacementUsingSameBSDName() async throws {
        let tracker = DeviceIOTracker()
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
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
        let replacement = EjectWorkflowTarget(
            deviceID: DeviceID(rawValue: "serial:replacement"),
            physicalBSDName: "disk4",
            mediaRegistryEntryID: 9_999,
            displayName: "Replacement",
            topologyGeneration: 2
        )

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: replacement,
            timeout: .milliseconds(100)
        )
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testPruningRemovedDeviceSessionClearsUnobservableSMARTScope() async throws {
        let tracker = DeviceIOTracker()
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
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
        let device = makeDevice("disk4")
        _ = await client.refreshSMART(for: device)

        await tracker.pruneSMARTSafetyScopes(
            liveDeviceIDs: [],
            livePhysicalBSDNames: [],
            topologyGeneration: 2
        )
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(100)
        )
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testOlderTopologyPruneCannotClearNewerSMARTSafetyScope() async throws {
        let tracker = DeviceIOTracker()
        let deviceID = DeviceID(rawValue: "session:new:disk4")
        await tracker.pruneSMARTSafetyScopes(
            liveDeviceIDs: [deviceID],
            livePhysicalBSDNames: ["disk4"],
            topologyGeneration: 2
        )
        let token = try await tracker.beginTargetOperation(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            topologyGeneration: 2,
            kind: .smart
        )
        await tracker.markSMARTCompletionUnobservable(token)

        await tracker.pruneSMARTSafetyScopes(
            liveDeviceIDs: [],
            livePhysicalBSDNames: [],
            topologyGeneration: 1
        )

        let target = EjectWorkflowTarget(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            mediaRegistryEntryID: 1,
            displayName: "disk4",
            topologyGeneration: 2
        )
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: target,
            timeout: .milliseconds(20)
        )
        do {
            try await barrier.waitUntilReady()
            XCTFail("An older topology prune must not clear a newer safety scope")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .legacySMARTCompletionUnobservable)
        }
        await barrier.release()
    }

    func testObservableSMARTCompletionClearsPriorFailClosedScopeForSameSession() async throws {
        let tracker = DeviceIOTracker()
        let deviceID = DeviceID(rawValue: "session:current:disk4")
        let failed = try await tracker.beginTargetOperation(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            topologyGeneration: 3,
            kind: .smart
        )
        await tracker.markSMARTCompletionUnobservable(failed)
        let retry = try await tracker.beginTargetOperation(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            topologyGeneration: 3,
            kind: .smart
        )
        await tracker.finishSMARTCompletion(retry, clearsPriorSafetyScopes: true)

        let target = EjectWorkflowTarget(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            mediaRegistryEntryID: 1,
            displayName: "disk4",
            topologyGeneration: 3
        )
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: target,
            timeout: .milliseconds(100)
        )
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testOlderObservableCompletionCannotClearNewerFailureScope() async throws {
        let tracker = DeviceIOTracker()
        let deviceID = DeviceID(rawValue: "session:current:disk4")
        let old = try await tracker.beginTargetOperation(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            topologyGeneration: 3,
            kind: .smart
        )
        let newer = try await tracker.beginTargetOperation(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            topologyGeneration: 4,
            kind: .smart
        )
        await tracker.markSMARTCompletionUnobservable(newer)
        await tracker.finishSMARTCompletion(old, clearsPriorSafetyScopes: true)

        let target = EjectWorkflowTarget(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            mediaRegistryEntryID: 1,
            displayName: "disk4",
            topologyGeneration: 4
        )
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: target,
            timeout: .milliseconds(20)
        )
        do {
            try await barrier.waitUntilReady()
            XCTFail("An older completion must not clear a newer failure scope")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .legacySMARTCompletionUnobservable)
        }
        await barrier.release()
    }

    func testFirstOlderPruneCannotClearFutureFailureScope() async throws {
        let tracker = DeviceIOTracker()
        let deviceID = DeviceID(rawValue: "session:future:disk4")
        let future = try await tracker.beginTargetOperation(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            topologyGeneration: 5,
            kind: .smart
        )
        await tracker.markSMARTCompletionUnobservable(future)
        await tracker.pruneSMARTSafetyScopes(
            liveDeviceIDs: [],
            livePhysicalBSDNames: [],
            topologyGeneration: 4
        )

        let target = EjectWorkflowTarget(
            deviceID: deviceID,
            physicalBSDName: "disk4",
            mediaRegistryEntryID: 1,
            displayName: "disk4",
            topologyGeneration: 5
        )
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: target,
            timeout: .milliseconds(20)
        )
        do {
            try await barrier.waitUntilReady()
            XCTFail("A stale first prune must preserve future scopes")
        } catch {
            XCTAssertEqual(error as? DeviceIOQuiescenceError, .legacySMARTCompletionUnobservable)
        }
        await barrier.release()
    }

    func testBusinessFailureEnvelopeWithProcessExitSafelyFinishesTracker() async throws {
        let tracker = DeviceIOTracker()
        let device = makeDevice("disk4")
        let prior = try await tracker.beginTargetOperation(
            deviceID: device.id,
            physicalBSDName: "disk4",
            topologyGeneration: 4,
            kind: .smart
        )
        await tracker.markSMARTCompletionUnobservable(prior)
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in Data() },
            readSMARTDataWithCompletion: { requestData in
                let request = try PalmosXPCMessages.decodeSMARTReadRequest(from: requestData)
                return try PalmosXPCMessages.encodeSMARTReadCompletionResponse(.init(
                    schemaVersion: 1,
                    payload: Data(),
                    processDidExit: true,
                    deviceSMARTIOQuiesced: true,
                    requestID: request.requestID,
                    error: .init(code: .timedOut, message: "Timed out")
                ))
            },
            deviceIOTracker: tracker
        )

        let result = await client.refreshSMART(for: device, topologyGeneration: 4)
        XCTAssertEqual(result, .failed("Timed out"))

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"),
            timeout: .milliseconds(100)
        )
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testPreAdmissionCompletionCannotClearPriorFailClosedScope() async throws {
        for quiescedEvidence in [false, nil] as [Bool?] {
            for errorCode in [SMARTReadCompletionErrorCode.busy, .duplicateRequest] {
                let tracker = DeviceIOTracker()
                let device = makeDevice("disk4")
                let prior = try await tracker.beginTargetOperation(
                    deviceID: device.id,
                    physicalBSDName: "disk4",
                    topologyGeneration: 4,
                    kind: .smart
                )
                await tracker.markSMARTCompletionUnobservable(prior)
                let handshake = try PalmosXPCMessages.encode(HelperHandshake(
                    helperVersion: "1.0.0",
                    contractMajor: XPCContractVersion.currentMajor,
                    contractMinor: XPCContractVersion.currentMinor
                ))
                let client = SMARTServiceClient(
                    fetchHelperHandshake: { handshake },
                    readSMARTData: { _ in Data() },
                    readSMARTDataWithCompletion: { requestData in
                        let request = try PalmosXPCMessages.decodeSMARTReadRequest(from: requestData)
                        return try PalmosXPCMessages.encodeSMARTReadCompletionResponse(.init(
                            schemaVersion: 1,
                            payload: Data(),
                            processDidExit: true,
                            deviceSMARTIOQuiesced: quiescedEvidence,
                            requestID: request.requestID,
                            error: .init(code: errorCode, message: "Rejected before launch")
                        ))
                    },
                    deviceIOTracker: tracker
                )

                _ = await client.refreshSMART(for: device, topologyGeneration: 4)

                let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
                    for: makeTarget("disk4"),
                    timeout: .milliseconds(20)
                )
                do {
                    try await barrier.waitUntilReady()
                    XCTFail("Pre-admission completion must preserve prior fail-closed scope")
                } catch {
                    XCTAssertEqual(
                        error as? DeviceIOQuiescenceError,
                        .legacySMARTCompletionUnobservable
                    )
                }
                await barrier.release()
            }
        }
    }

    func testSMARTCancellationKeepsTokenUntilAcknowledgedReplyThenReleasesExactlyOnce() async throws {
        let tracker = DeviceIOTracker()
        let replyGate = AsyncSuspensionGate()
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in Data() },
            readSMARTDataWithCompletion: { requestData in
                await replyGate.wait()
                let request = try PalmosXPCMessages.decodeSMARTReadRequest(from: requestData)
                return try PalmosXPCMessages.encodeSMARTReadCompletionResponse(.init(
                    schemaVersion: 1,
                    payload: Data("{}".utf8),
                    processDidExit: true,
                    requestID: request.requestID
                ))
            },
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

    func testCompletionSessionCancellationWaitsForObservableProcessExit() async throws {
        let tracker = DeviceIOTracker()
        let session = ControlledSMARTXPCSession()
        let client = try makeSessionClient(tracker: tracker, session: session)
        let device = makeDevice("disk4")
        let refresh = Task { await client.refreshSMART(for: device) }
        await session.waitUntilHandlerInstalled()

        refresh.cancel()
        while session.wasInvalidated == false { await Task.yield() }
        XCTAssertTrue(session.wasInvalidated)
        let response = try PalmosXPCMessages.encodeSMARTReadCompletionResponse(.init(
            schemaVersion: 1,
            payload: Data(),
            processDidExit: true,
            requestID: try XCTUnwrap(session.currentRequestID),
            error: .init(code: .cancelled, message: "Cancelled")
        ))
        session.emit(.reply(response))
        _ = await refresh.value

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .milliseconds(100)
        )
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testConcurrentSMARTRefreshesOwnIndependentCompletionSessions() async throws {
        let tracker = DeviceIOTracker()
        let sessionA = ControlledSMARTXPCSession()
        let sessionB = ControlledSMARTXPCSession()
        let sessions = SMARTCompletionSessionQueue([sessionA, sessionB])
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in Data() },
            completionSessionFactory: sessions.makeSession,
            deviceIOTracker: tracker
        )

        let deviceA = makeDevice("disk4")
        let deviceB = makeDevice("disk5")
        let refreshA = Task { await client.refreshSMART(for: deviceA) }
        await sessionA.waitUntilHandlerInstalled()
        let refreshB = Task { await client.refreshSMART(for: deviceB) }
        await sessionB.waitUntilHandlerInstalled()

        refreshA.cancel()
        while sessionA.wasInvalidated == false { await Task.yield() }
        let cancelledResponse = try PalmosXPCMessages.encodeSMARTReadCompletionResponse(.init(
            schemaVersion: 1,
            payload: Data(),
            processDidExit: true,
            requestID: try XCTUnwrap(sessionA.currentRequestID),
            error: .init(code: .cancelled, message: "Cancelled")
        ))
        sessionA.emit(.reply(cancelledResponse))
        _ = await refreshA.value
        XCTAssertTrue(sessionA.wasInvalidated)
        XCTAssertFalse(sessionB.wasInvalidated)

        let response = try PalmosXPCMessages.encodeSMARTReadCompletionResponse(.init(
            schemaVersion: 1,
            payload: Data("{}".utf8),
            processDidExit: true,
            requestID: try XCTUnwrap(sessionB.currentRequestID)
        ))
        sessionB.emit(.reply(response))
        guard case .available = await refreshB.value else {
            return XCTFail("Cancelling device A must not cancel device B")
        }
        XCTAssertFalse(sessionB.wasInvalidated)
    }

    func testCancellationBeforeHandshakeCompletionNeverStartsCompletionSession() async throws {
        let handshakeGate = AsyncSuspensionGate()
        let session = ControlledSMARTXPCSession()
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let client = SMARTServiceClient(
            fetchHelperHandshake: {
                await handshakeGate.wait()
                return handshake
            },
            readSMARTData: { _ in Data() },
            completionSessionFactory: { session }
        )
        let device = makeDevice("disk4")
        let refresh = Task { await client.refreshSMART(for: device) }
        while await handshakeGate.waiterCount == 0 { await Task.yield() }

        refresh.cancel()
        await handshakeGate.releaseAll()
        _ = await refresh.value

        XCTAssertFalse(session.didStart)
        XCTAssertFalse(session.wasInvalidated)
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
        let response = try PalmosXPCMessages.encodeSMARTReadCompletionResponse(.init(
            schemaVersion: 1,
            payload: Data("{}".utf8),
            processDidExit: true,
            requestID: try XCTUnwrap(session.currentRequestID)
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
    func testCapacityReadsUnmappedAndResumesMappedResourceValuesAfterBarrierRelease() async throws {
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
        XCTAssertEqual(reads.value, 1)

        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .seconds(1)
        )
        refresher.start(
            mountPoints: ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(reads.value, 1)
        await barrier.release()

        let update = expectation(description: "capacity resumed")
        refresher.onUpdate = { _ in update.fulfill() }
        refresher.start(
            mountPoints: ["disk4s1": "/Volumes/Test"],
            physicalBSDNames: ["disk4s1": "disk4"]
        )
        await fulfillment(of: [update], timeout: 1)
        XCTAssertEqual(reads.value, 2)

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
                if commandArguments.first == "info" {
                    let container = commandArguments.last ?? ""
                    return try? PropertyListSerialization.data(
                        fromPropertyList: [
                            "DeviceIdentifier": container,
                            "Content": "EF57347C-0000-11AA-AA11-00306543ECAC",
                            "APFSContainerReference": container,
                            "APFSPhysicalStores": [[
                                "APFSPhysicalStore": container == "disk10" ? "disk4s2" : "disk5s2"
                            ]]
                        ], format: .xml, options: 0
                    )
                }
                return plist
            },
            deviceIOTracker: tracker
        )
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: makeTarget("disk4"), timeout: .seconds(1)
        )
        await provider.refresh(targets: [.init(physicalBSDName: "disk4", containerBSDName: "disk10")])
        XCTAssertEqual(calls.value, 0)
        await provider.refresh(targets: [.init(physicalBSDName: "disk5", containerBSDName: "disk11")])
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(arguments.values, [
            ["info", "-plist", "disk11"],
            ["apfs", "list", "-plist", "disk11"]
        ])
        await barrier.release()
        await provider.refresh(targets: [.init(physicalBSDName: "disk4", containerBSDName: "disk10")])
        XCTAssertEqual(calls.value, 4)
        XCTAssertEqual(arguments.values.last, ["apfs", "list", "-plist", "disk10"])

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
            commandRunner: { _, commandArguments in
                if commandArguments.first == "info" {
                    await gate.wait()
                    return try? PropertyListSerialization.data(
                        fromPropertyList: [
                            "DeviceIdentifier": "disk10",
                            "Content": "EF57347C-0000-11AA-AA11-00306543ECAC",
                            "APFSContainerReference": "disk10",
                            "APFSPhysicalStores": [["APFSPhysicalStore": "disk4s2"]]
                        ], format: .xml, options: 0
                    )
                }
                return plist
            },
            deviceIOTracker: tracker
        )
        let refresh = Task {
            await provider.refresh(targets: [.init(physicalBSDName: "disk4", containerBSDName: "disk10")])
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
            if commandArguments.first == "info" {
                let container = commandArguments.last ?? ""
                return try? PropertyListSerialization.data(
                    fromPropertyList: [
                        "DeviceIdentifier": container,
                        "Content": "EF57347C-0000-11AA-AA11-00306543ECAC",
                        "APFSContainerReference": container,
                        "APFSPhysicalStores": [[
                            "APFSPhysicalStore": container == "disk10" ? "disk4s2" : "disk5s2"
                        ]]
                    ], format: .xml, options: 0
                )
            }
            let physicalBSDName = commandArguments.last
            let containers: [[String: Any]]
            if physicalBSDName == "disk10" {
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

        await provider.refresh(targets: [
            .init(physicalBSDName: "disk5", containerBSDName: "disk11"),
            .init(physicalBSDName: "disk4", containerBSDName: "disk10")
        ])

        XCTAssertEqual(arguments.values, [
            ["info", "-plist", "disk10"],
            ["apfs", "list", "-plist", "disk10"],
            ["info", "-plist", "disk11"],
            ["apfs", "list", "-plist", "disk11"]
        ])
        let disk10 = await provider.containerInfo(forContainerBSDName: "disk10")
        let disk11 = await provider.containerInfo(forContainerBSDName: "disk11")
        XCTAssertEqual(disk10?.totalCapacityBytes, 100)
        XCTAssertEqual(disk11?.totalCapacityBytes, 200)
    }

    func testDiskutilResolvesContainerWithScopedInfoBeforeAPFSList() async throws {
        let arguments = LockedArray<[String]>()
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "DeviceIdentifier": "disk4s2",
                "Content": "Apple_APFS",
                "APFSContainerReference": "disk10"
            ], format: .xml, options: 0
        )
        let topology = try PropertyListSerialization.data(
            fromPropertyList: ["Containers": []], format: .xml, options: 0
        )
        let provider = LiveDiskUtilAPFSProvider(commandRunner: { _, commandArguments in
            arguments.append(commandArguments)
            return commandArguments.first == "info" ? info : topology
        })

        await provider.refresh(targets: [
            .init(physicalBSDName: "disk4s2", containerBSDName: nil)
        ])

        XCTAssertEqual(arguments.values, [
            ["info", "-plist", "disk4s2"],
            ["apfs", "list", "-plist", "disk10"]
        ])
    }

    func testDiskutilValidatesExpectedSynthesizedContainerInsteadOfGPTWholeDisk() async throws {
        let arguments = LockedArray<[String]>()
        let provider = LiveDiskUtilAPFSProvider(commandRunner: { _, commandArguments in
            arguments.append(commandArguments)
            if commandArguments == ["info", "-plist", "disk10"] {
                return try? PropertyListSerialization.data(
                    fromPropertyList: [
                        "DeviceIdentifier": "disk10",
                        "Content": "EF57347C-0000-11AA-AA11-00306543ECAC",
                        "APFSContainerReference": "disk10",
                        "APFSPhysicalStores": [["APFSPhysicalStore": "disk4s2"]]
                    ], format: .xml, options: 0
                )
            }
            if commandArguments == ["apfs", "list", "-plist", "disk10"] {
                return try? PropertyListSerialization.data(
                    fromPropertyList: [
                        "Containers": [[
                            "ContainerReference": "disk10",
                            "DesignatedPhysicalStore": "disk4s2",
                            "CapacityCeiling": 100,
                            "CapacityFree": 40,
                            "Volumes": []
                        ]]
                    ], format: .xml, options: 0
                )
            }
            return nil
        })

        await provider.refresh(targets: [
            .init(physicalBSDName: "disk4", containerBSDName: "disk10")
        ])

        XCTAssertEqual(arguments.values, [
            ["info", "-plist", "disk10"],
            ["apfs", "list", "-plist", "disk10"]
        ])
        let capacityInUse = await provider.containerInfo(
            forContainerBSDName: "disk10"
        )?.capacityInUseBytes
        XCTAssertEqual(capacityInUse, 60)
    }

    func testDiskutilNonAPFSOrMismatchedInfoFailsClosedWithoutAPFSList() async throws {
        for infoValues: [String: Any] in [
            ["DeviceIdentifier": "disk4s2", "Content": "Microsoft Basic Data"],
            ["DeviceIdentifier": "disk9s2", "Content": "Apple_APFS", "APFSContainerReference": "disk10"]
        ] {
            let arguments = LockedArray<[String]>()
            let info = try PropertyListSerialization.data(
                fromPropertyList: infoValues, format: .xml, options: 0
            )
            let provider = LiveDiskUtilAPFSProvider(commandRunner: { _, commandArguments in
                arguments.append(commandArguments)
                return info
            })
            await provider.refresh(targets: [
                .init(physicalBSDName: "disk4s2", containerBSDName: nil)
            ])
            XCTAssertEqual(arguments.values, [["info", "-plist", "disk4s2"]])
        }
    }

    func testDiskutilStaleCandidateMismatchFailsClosedWithoutAPFSList() async throws {
        let arguments = LockedArray<[String]>()
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "DeviceIdentifier": "disk10",
                "Content": "EF57347C-0000-11AA-AA11-00306543ECAC",
                "APFSContainerReference": "disk12",
                "APFSPhysicalStores": [["APFSPhysicalStore": "disk4s2"]]
            ], format: .xml, options: 0
        )
        let provider = LiveDiskUtilAPFSProvider(commandRunner: { _, commandArguments in
            arguments.append(commandArguments)
            return info
        })

        await provider.refresh(targets: [
            .init(physicalBSDName: "disk4s2", containerBSDName: "disk10")
        ])

        XCTAssertEqual(arguments.values, [["info", "-plist", "disk10"]])
    }

    func testSystemProfilerSpawnsDoNotDelayTargetBarrier() async throws {
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
        try await barrier.waitUntilReady()
        await gate.releaseAll()
        await refresh.value
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

    func testSubprocessCancellationEscalatesWhenProcessIgnoresTERM() async {
        let start = ContinuousClock.now
        let task = Task {
            await SubprocessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; exec /bin/sleep 10"]
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSubprocessCancellationBeforeLaunchPreventsTERMResistantProcessFromRunning() async {
        let prepared = LockedFlag()
        let releaseLaunch = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now
        let task = Task {
            await SubprocessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; exec /bin/sleep 10"],
                processPrepared: {
                    prepared.setTrue()
                    releaseLaunch.wait()
                }
            )
        }
        while prepared.value == false { await Task.yield() }
        task.cancel()
        releaseLaunch.signal()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testProcessBoxDelayedKillRequiresSameProcessObject() async throws {
        let processBox = ProcessBox()
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf ready; exec /bin/sleep 10"]
        process.standardOutput = stdoutPipe

        processBox.set(process)
        try process.run()
        processBox.processDidStart(process)
        let ready = stdoutPipe.fileHandleForReading.readData(ofLength: 5)
        XCTAssertEqual(ready, Data("ready".utf8))

        processBox.terminateAndEscalate()
        processBox.clear(process)
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(process.isRunning)
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    func testSubprocessDiscardsStdoutFromNonzeroExit() async {
        let data = await SubprocessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf partial; exit 7"]
        )
        XCTAssertNil(data)
    }

    func testSubprocessDiscardsPartialStdoutWhenCancelledBySignal() async {
        let task = Task {
            await SubprocessRunner.run(
                executable: "/bin/sh",
                arguments: ["-c", "printf partial; exec /bin/sleep 10"]
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let data = await task.value
        XCTAssertNil(data)
    }

    func testSubprocessReturnsStdoutOnlyForNormalZeroExit() async {
        let data = await SubprocessRunner.run(
            executable: "/usr/bin/printf",
            arguments: ["complete"]
        )
        XCTAssertEqual(data, Data("complete".utf8))
    }

    func testSubprocessEnforcesOutputLimit() async {
        let start = ContinuousClock.now
        let data = await SubprocessRunner.run(
            executable: "/usr/bin/yes",
            arguments: ["oversized"],
            maxOutputBytes: 4 * 1024,
            timeout: .seconds(2)
        )
        XCTAssertNil(data)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSubprocessEnforcesDeadline() async {
        let start = ContinuousClock.now
        let data = await SubprocessRunner.run(
            executable: "/bin/sleep",
            arguments: ["10"],
            timeout: .milliseconds(50)
        )
        XCTAssertNil(data)
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
            sessionMetrics: .empty(),
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
        catch { XCTAssertEqual(error as? DeviceIOQuiescenceError, .legacySMARTCompletionUnobservable) }
        await barrier.release()
    }

    private func makeSessionClient(
        tracker: DeviceIOTracker,
        session: ControlledSMARTXPCSession
    ) throws -> SMARTServiceClient {
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func setTrue() { lock.withLock { storage = true } }
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
    private var invalidated = false
    private var requestID: String?

    var wasInvalidated: Bool { lock.withLock { invalidated } }
    var didStart: Bool { lock.withLock { handler != nil } }
    var currentRequestID: String? { lock.withLock { requestID } }

    func readSMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        let requestID = try? PalmosXPCMessages.decodeSMARTReadRequest(from: requestData).requestID
        lock.withLock {
            handler = eventHandler
            self.requestID = requestID
        }
    }

    func waitUntilHandlerInstalled() async {
        while lock.withLock({ handler == nil }) { await Task.yield() }
    }

    func emit(_ event: SMARTXPCSessionEvent) {
        lock.withLock { handler }?(event)
    }

    func invalidate() {
        lock.withLock { invalidated = true }
    }
}

private final class SMARTCompletionSessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ControlledSMARTXPCSession]

    init(_ sessions: [ControlledSMARTXPCSession]) {
        self.sessions = sessions
    }

    func makeSession() -> any SMARTCompletionXPCSession {
        lock.withLock { sessions.removeFirst() }
    }
}
