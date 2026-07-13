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
}
