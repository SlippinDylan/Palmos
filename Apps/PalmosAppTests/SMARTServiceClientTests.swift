import XCTest
@testable import PalmosApp
import PalmosCore
import SwiftUI

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    var value: Data? { lock.withLock { stored } }
    func set(_ data: Data) { lock.withLock { stored = data } }
}

final class SMARTServiceClientTests: XCTestCase {
    func testErrorMapperKeepsHelperInstallationEvidenceAtBoundary() {
        let connectionError = SMARTServiceClientError.connectionInterrupted
        let installedMapper = SMARTServiceErrorMapper(isHelperInstalled: { true })
        let absentMapper = SMARTServiceErrorMapper(isHelperInstalled: { false })

        guard case .failed = installedMapper.mapRefreshError(connectionError) else {
            return XCTFail("An installed helper connection failure must remain visible")
        }
        XCTAssertEqual(
            absentMapper.mapRefreshError(connectionError),
            .helperNotInstalled
        )
    }

    func testCompanionInstallSendsBoundedRequestAndConfirmsHandshake() async throws {
        let binary = Data([0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3])
        let requestBox = LockedDataBox()
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor,
            smartctlCompanionAvailable: true
        ))
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            installSmartctlCompanion: { requestData in
                requestBox.set(requestData)
                return try PalmosXPCMessages.encodeSMARTCompanionInstallAcknowledgement(
                    .init(
                        schemaVersion: SMARTCompanionInstallAcknowledgement.currentSchemaVersion,
                        result: .installed
                    )
                )
            }
        )

        try await client.installBundledSmartctlCompanion(binary)

        let request = try PalmosXPCMessages.decodeSMARTCompanionInstallRequest(
            from: XCTUnwrap(requestBox.value)
        )
        XCTAssertEqual(request.binary, binary)
    }

    func testCompanionInstallRequiresPostInstallCapabilityConfirmation() async throws {
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.0.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor,
            smartctlCompanionAvailable: false
        ))
        let acknowledgement = try PalmosXPCMessages.encodeSMARTCompanionInstallAcknowledgement(
            .init(
                schemaVersion: SMARTCompanionInstallAcknowledgement.currentSchemaVersion,
                result: .installed
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            installSmartctlCompanion: { _ in acknowledgement }
        )

        do {
            try await client.installBundledSmartctlCompanion(Data([0xcf, 0xfa, 0xed, 0xfe]))
            XCTFail("Expected unavailable companion confirmation to fail")
        } catch let error as SMARTServiceClientError {
            XCTAssertEqual(error, .companionInstallationUnconfirmed)
        }
    }

    func testCancellingOccupancyXPCInvalidatesSessionAndIgnoresLateReply() async throws {
        let workflowID = UUID()
        let session = ControlledOccupancyXPCSession(synchronouslyInvalidates: true)
        let client = SMARTServiceClient(
            occupancySessionFactory: { session }
        )
        let task = Task {
            try await client.scan(workflowID: workflowID, physicalBSDName: "disk4")
        }
        try await session.waitUntilHandshakeStarted()
        session.sendHandshake(.reply(try currentHandshakeData()))
        try await session.waitUntilStarted()

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled occupancy scan should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertEqual(session.invalidationCount, 1)

        session.send(.reply(try PalmosXPCMessages.encodeOccupancyResponse(.init(
            workflowID: workflowID,
            holders: [.init(pid: 7, executableName: "late", displayName: nil, type: "unknown")],
            isComplete: true
        ))))
        await Task.yield()
        XCTAssertEqual(session.invalidationCount, 1)
    }

    func testCancellingPendingOccupancyHandshakeInvalidatesAndNeverStartsScan() async throws {
        let session = ControlledOccupancyXPCSession(synchronouslyInvalidates: true)
        let client = SMARTServiceClient(occupancySessionFactory: { session })
        let task = Task { try await client.scan(workflowID: UUID(), physicalBSDName: "disk4") }
        try await session.waitUntilHandshakeStarted()

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled handshake should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(session.invalidationCount, 1)
        XCTAssertEqual(session.scanCount, 0)

        session.sendHandshake(.reply(try currentHandshakeData()))
        await Task.yield()
        XCTAssertEqual(session.scanCount, 0)
    }

    func testOverlappingOccupancyScansOwnIndependentSessions() async throws {
        let sessionA = ControlledOccupancyXPCSession()
        let sessionB = ControlledOccupancyXPCSession()
        let factory = ControlledOccupancySessionFactory(sessions: [sessionA, sessionB])
        let client = SMARTServiceClient(occupancySessionFactory: factory.makeSession)
        let workflowA = UUID()
        let workflowB = UUID()
        let taskA = Task { try await client.scan(workflowID: workflowA, physicalBSDName: "disk4") }
        try await sessionA.waitUntilHandshakeStarted()
        let taskB = Task { try await client.scan(workflowID: workflowB, physicalBSDName: "disk5") }
        try await sessionB.waitUntilHandshakeStarted()
        let handshake = try currentHandshakeData()
        sessionA.sendHandshake(.reply(handshake))
        sessionB.sendHandshake(.reply(handshake))
        try await sessionA.waitUntilStarted()
        try await sessionB.waitUntilStarted()

        taskA.cancel()
        do {
            _ = try await taskA.value
            XCTFail("Cancelled request A should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(sessionA.invalidationCount, 1)
        XCTAssertEqual(sessionB.invalidationCount, 0)

        sessionB.send(.reply(try PalmosXPCMessages.encodeOccupancyResponse(.init(
            workflowID: workflowB,
            holders: [],
            isComplete: true
        ))))
        let resultB = try await taskB.value
        XCTAssertEqual(resultB, OccupancyScanResult(holders: [], isComplete: true))

        sessionA.send(.reply(try PalmosXPCMessages.encodeOccupancyResponse(.init(
            workflowID: workflowA,
            holders: [.init(pid: 99, executableName: "late", displayName: nil, type: "unknown")],
            isComplete: true
        ))))
        await Task.yield()
        XCTAssertEqual(sessionB.invalidationCount, 0)
    }

    func testOccupancyScanRejectsResponseForAnotherWorkflow() async throws {
        let handshake = try PalmosXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.4.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            scanDiskOccupancy: { _ in
                try PalmosXPCMessages.encodeOccupancyResponse(.init(
                    workflowID: UUID(),
                    holders: [],
                    isComplete: true
                ))
            }
        )

        do {
            _ = try await client.scan(workflowID: UUID(), physicalBSDName: "disk4")
            XCTFail("Mismatched workflow response should be rejected")
        } catch {
            XCTAssertFalse(error is CancellationError)
            XCTAssertEqual(
                error.localizedDescription,
                "The SMART helper returned an occupancy result for another workflow."
            )
        }
    }

    private func currentHandshakeData() throws -> Data {
        try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.4.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
    }

    func testOccupancyScanDegradesHonestlyWithoutCallingUnsupportedOldHelperEndpoint() async throws {
        let handshake = try PalmosXPCMessages.encode(
            HelperHandshake(helperVersion: "1.3.0", contractMajor: 1, contractMinor: 3)
        )
        let scanCallCount = LockedCounter()
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            scanDiskOccupancy: { _ in
                scanCallCount.increment()
                return Data()
            }
        )

        let result = try await client.scan(workflowID: UUID(), physicalBSDName: "disk4")

        XCTAssertEqual(result, .init(holders: [], isComplete: false))
        XCTAssertEqual(scanCallCount.value, 0)
    }

    func testOccupancyScanUsesCapabilityAndMapsBoundedResponse() async throws {
        let handshake = try PalmosXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.4.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let workflowID = UUID()
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            scanDiskOccupancy: { requestData in
                let request = try PalmosXPCMessages.decodeOccupancyRequest(from: requestData)
                XCTAssertEqual(request, .init(workflowID: workflowID, physicalDeviceBSDName: "disk4"))
                return try PalmosXPCMessages.encodeOccupancyResponse(.init(
                    workflowID: workflowID,
                    holders: [.init(
                        pid: 17,
                        executableName: "terminal",
                        displayName: "Terminal",
                        type: OccupancyType.workingDirectory.rawValue
                    )],
                    isComplete: true
                ))
            }
        )

        let result = try await client.scan(workflowID: workflowID, physicalBSDName: "disk4")

        XCTAssertEqual(result, .init(
            holders: [.init(
                pid: 17,
                executableName: "terminal",
                displayName: "Terminal",
                type: .workingDirectory
            )],
            isComplete: true
        ))
    }

    func testCompatibilityFromEncodedHandshakeUsesSerializedContractFields() throws {
        let client = SMARTServiceClient()
        let payload = HelperHandshake(
            helperVersion: "9.9.9",
            contractMajor: 1,
            contractMinor: 1
        )
        let encodedPayload = try PalmosXPCMessages.encode(payload)

        let result = try client.evaluateHandshake(from: encodedPayload)

        XCTAssertEqual(result, .degraded)
    }

    func testHandshakeDecodeRejectsOversizedPayloadBeforeJSONDecode() {
        let client = SMARTServiceClient()

        XCTAssertThrowsError(
            try client.evaluateHandshake(
                from: Data(repeating: 0, count: SMARTXPCLimits.handshakeBytes + 1)
            )
        )
    }

    func testHelperInspectionReportsNotInstalledWithoutOpeningXPCConnection() async {
        let handshakeFetchCount = LockedCounter()
        let client = SMARTServiceClient(
            isHelperInstalled: { false },
            fetchHelperHandshake: {
                handshakeFetchCount.increment()
                return Data()
            }
        )

        let result = await client.inspectSMARTHelper()

        XCTAssertEqual(result, .notInstalled)
        XCTAssertEqual(handshakeFetchCount.value, 0)
    }

    func testHelperInspectionUsesHandshakeCompatibility() async throws {
        let currentHandshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.4.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        ))
        let outdatedHandshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "0.9.0",
            contractMajor: XPCContractVersion.currentMajor + 1,
            contractMinor: 0
        ))
        let unavailableHandshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.4.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor,
            smartctlCompanionAvailable: false
        ))
        let installedClient = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: { currentHandshake }
        )
        let outdatedClient = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: { outdatedHandshake }
        )
        let unavailableClient = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: { unavailableHandshake }
        )

        let installedResult = await installedClient.inspectSMARTHelper()
        let outdatedResult = await outdatedClient.inspectSMARTHelper()
        let unavailableResult = await unavailableClient.inspectSMARTHelper()

        XCTAssertEqual(installedResult, .installed)
        XCTAssertEqual(outdatedResult, .updateRequired)
        XCTAssertEqual(unavailableResult, .companionUnavailable)
    }

    func testHelperInspectionKeepsInstalledConnectionFailureVisible() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: {
                throw NSError(
                    domain: "PalmosTests",
                    code: 17,
                    userInfo: [NSLocalizedDescriptionKey: "Handshake failed"]
                )
            }
        )

        let result = await client.inspectSMARTHelper()

        XCTAssertEqual(result, .failed("Handshake failed"))
    }

    func testEncodeReadRequestRoundTripsThroughSharedMessageCodec() throws {
        let client = SMARTServiceClient()
        let request = SMARTReadRequest(
            physicalDeviceBSDName: "disk42",
            deviceProtocol: "USB",
            deviceModel: "Field SSD"
        )

        let encodedRequest = try client.encodeReadRequest(request)
        let decodedRequest = try PalmosXPCMessages.decode(
            SMARTReadRequest.self,
            from: encodedRequest
        )

        XCTAssertEqual(decodedRequest, request)
    }

    func testEncodeReadRequestRejectsOversizedModel() {
        let client = SMARTServiceClient()
        let request = SMARTReadRequest(
            physicalDeviceBSDName: "disk42",
            deviceProtocol: "USB",
            deviceModel: String(repeating: "x", count: SMARTXPCLimits.requestBytes)
        )

        XCTAssertThrowsError(try client.encodeReadRequest(request))
    }

    func testRefreshSMARTMapsMissingHelperConnectionToHelperNotInstalled() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { false },
            fetchHelperHandshake: {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: 4099,
                    userInfo: [NSLocalizedDescriptionKey: "connection invalid"]
                )
            },
            readSMARTData: { _ in
                XCTFail("SMART read should not be attempted when handshake fails")
                return Data()
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk42"))

        XCTAssertEqual(result, .helperNotInstalled)
    }

    func testMinorFiveHelperDegradesOnlySMARTMonitoringWithoutStartingUnobservableRead() async throws {
        let tracker = DeviceIOTracker()
        let reads = LockedCounter()
        let handshake = try PalmosXPCMessages.encode(HelperHandshake(
            helperVersion: "1.5.0",
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.legacySMARTCancellationMinor,
            smartctlCompanionAvailable: true
        ))
        let client = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                reads.increment()
                throw NSError(domain: "legacy", code: 1)
            },
            deviceIOTracker: tracker
        )
        let device = makeClientDevice(id: "disk4")

        XCTAssertEqual(
            client.evaluateHandshake(try client.decodeHandshake(from: handshake)),
            .degraded
        )
        let inspection = await client.inspectSMARTHelper()
        XCTAssertEqual(inspection, .monitoringUpdateRequired)
        let result = await client.refreshSMART(for: device)
        XCTAssertEqual(result, .updateRequired)
        XCTAssertEqual(reads.value, 0)
        let barrier = try await DeviceIOQuiescer(tracker: tracker).acquireBarrier(
            for: EjectWorkflowTarget(
                deviceID: device.id,
                physicalBSDName: "disk4",
                mediaRegistryEntryID: 1,
                displayName: "disk4",
                topologyGeneration: 1
            ),
            timeout: .milliseconds(100)
        )
        try await barrier.waitUntilReady()
        await barrier.release()
    }

    func testRefreshSMARTDoesNotTreatInstalledHelperConnectionFailureAsMissingHelper() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: 4099,
                    userInfo: [NSLocalizedDescriptionKey: "connection invalid"]
                )
            },
            readSMARTData: { _ in
                XCTFail("SMART read should not be attempted when handshake fails")
                return Data()
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk4100"))

        XCTAssertEqual(result, .failed("connection invalid"))
    }

    func testRefreshSMARTMapsMissingHelperInterruptionToHelperNotInstalled() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { false },
            fetchHelperHandshake: {
                throw SMARTServiceClientError.connectionInterrupted
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk-interrupted"))

        XCTAssertEqual(result, .helperNotInstalled)
    }

    func testRefreshSMARTMapsMissingHelperInvalidationToHelperNotInstalled() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { false },
            fetchHelperHandshake: {
                throw SMARTServiceClientError.connectionInvalidated
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk-invalidated"))

        XCTAssertEqual(result, .helperNotInstalled)
    }

    func testRefreshSMARTKeepsInstalledHelperInterruptionAsConnectionFailure() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { true },
            fetchHelperHandshake: {
                throw SMARTServiceClientError.connectionInterrupted
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk-installed"))

        XCTAssertEqual(
            result,
            .failed(SMARTServiceClientError.connectionInterrupted.localizedDescription)
        )
    }

    func testRefreshSMARTDoesNotTreatArbitraryConnectionStringAsMissingHelper() async {
        let client = SMARTServiceClient(
            isHelperInstalled: { false },
            fetchHelperHandshake: {
                throw NSError(
                    domain: "PalmosTests",
                    code: 77,
                    userInfo: [NSLocalizedDescriptionKey: "connection invalid"]
                )
            },
            readSMARTData: { _ in
                XCTFail("SMART read should not be attempted when handshake fails")
                return Data()
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk77"))

        XCTAssertEqual(result, .failed("connection invalid"))
    }

    func testRefreshSMARTMapsPermissionErrorFromRead() async throws {
        let handshake = try PalmosXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk24"))

        XCTAssertEqual(result, .permissionRequired)
    }

    func testRefreshSMARTMapsUnsupportedDeviceMessageToDeviceUnavailable() async throws {
        let handshake = try PalmosXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(
                    domain: "PalmosTests",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported SMART device name: disk7"]
                )
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk7"))

        XCTAssertEqual(result, .deviceUnavailable)
    }

    func testRefreshSMARTMapsTransportHintFailureToTransportUnsupported() async throws {
        let handshake = try PalmosXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(
                    domain: "PalmosTests",
                    code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "smartctl failed with exit code 2 using transport hint nvme: Unknown USB bridge"]
                )
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk9"))

        XCTAssertEqual(result, .transportUnsupported)
    }

    func testRefreshSMARTMapsMissingSMARTCapabilityToUnsupported() async throws {
        let handshake = try PalmosXPCMessages.encode(
            HelperHandshake(
                helperVersion: "1.0.0",
                contractMajor: XPCContractVersion.currentMajor,
                contractMinor: XPCContractVersion.currentMinor
            )
        )
        let client = SMARTServiceClient(
            fetchHelperHandshake: { handshake },
            readSMARTData: { _ in
                throw NSError(
                    domain: "PalmosTests",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "SMART support is unavailable for this device"]
                )
            }
        )

        let result = await client.refreshSMART(for: makeClientDevice(id: "disk11"))

        XCTAssertEqual(result, .unsupported)
    }

    private func makeClientDevice(id rawID: String) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: rawID),
            displayName: "Device \(rawID)",
            transportName: "USB",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(),
            physicalStoreBSDName: rawID,
            apfsContainerBSDName: nil,
            volumes: []
        )
    }
}

private final class ControlledOccupancyXPCSession: OccupancyXPCSession, @unchecked Sendable {
    private let lock = NSLock()
    private var handshakeHandler: (@Sendable (SMARTXPCSessionEvent) -> Void)?
    private var eventHandler: (@Sendable (SMARTXPCSessionEvent) -> Void)?
    private var handshakeStarted = false
    private var started = false
    private var invalidations = 0
    private let synchronouslyInvalidates: Bool

    var invalidationCount: Int { lock.withLock { invalidations } }
    var scanCount: Int { lock.withLock { started ? 1 : 0 } }

    init(synchronouslyInvalidates: Bool = false) {
        self.synchronouslyInvalidates = synchronouslyInvalidates
    }

    func fetchHelperHandshake(
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        lock.withLock {
            handshakeStarted = true
            handshakeHandler = eventHandler
        }
    }

    func scanDiskOccupancy(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        lock.withLock {
            started = true
            self.eventHandler = eventHandler
        }
    }

    func invalidate() {
        let handler = lock.withLock {
            invalidations += 1
            return eventHandler ?? handshakeHandler
        }
        if synchronouslyInvalidates { handler?(.invalidated) }
    }

    func waitUntilHandshakeStarted() async throws {
        try await waitUntil { self.handshakeStarted }
    }

    func waitUntilStarted() async throws {
        try await waitUntil { self.started }
    }

    func send(_ event: SMARTXPCSessionEvent) {
        lock.withLock { eventHandler }?(event)
    }

    func sendHandshake(_ event: SMARTXPCSessionEvent) {
        lock.withLock { handshakeHandler }?(event)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lock.withLock({ condition() == false }) {
            guard ContinuousClock.now < deadline else { throw OccupancySessionTestError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class ControlledOccupancySessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ControlledOccupancyXPCSession]

    init(sessions: [ControlledOccupancyXPCSession]) {
        self.sessions = sessions
    }

    func makeSession() -> any OccupancyXPCSession {
        lock.withLock { sessions.removeFirst() }
    }
}

private enum OccupancySessionTestError: Error {
    case timedOut
}

@MainActor
final class SMARTHelperManagerTests: XCTestCase {
    func testRefreshPublishesInspectedStatus() async {
        let manager = SMARTHelperManager(
            inspector: StubSMARTHelperInspector(result: .updateRequired),
            installer: StubHelperInstaller()
        )

        manager.refreshStatus()
        while manager.status == .checking {
            await Task.yield()
        }

        XCTAssertEqual(manager.status, .updateRequired)
    }

    func testSuccessfulInstallPublishesInspectedCapability() async {
        let installer = StubHelperInstaller()
        let manager = SMARTHelperManager(
            inspector: StubSMARTHelperInspector(result: .installed),
            installer: installer
        )

        let installed = await manager.installOrUpdate()
        let installCallCount = await installer.installCallCount

        XCTAssertTrue(installed)
        XCTAssertEqual(manager.status, .installed)
        XCTAssertEqual(installCallCount, 1)
    }

    func testSuccessfulInstallDoesNotClaimSMARTWhenCompanionIsUnavailable() async {
        let manager = SMARTHelperManager(
            inspector: StubSMARTHelperInspector(result: .companionUnavailable),
            installer: StubHelperInstaller()
        )

        let installed = await manager.installOrUpdate()
        XCTAssertTrue(installed)
        XCTAssertEqual(manager.status, .companionUnavailable)
    }

    func testPostInstallInspectionCannotOverwriteNewerDeviceEvidence() async {
        let inspector = ControlledSMARTHelperInspector()
        let manager = SMARTHelperManager(
            inspector: inspector,
            installer: StubHelperInstaller()
        )

        let installation = Task { await manager.installOrUpdate() }
        await inspector.waitUntilInspectionStarts()
        manager.record(.companionUnavailable)
        await inspector.finish(with: .installed)

        let installed = await installation.value
        XCTAssertTrue(installed)
        XCTAssertEqual(manager.status, .companionUnavailable)
    }

    func testRefreshPublishesMonitoringSpecificUpdateStatus() async {
        let manager = SMARTHelperManager(
            inspector: StubSMARTHelperInspector(result: .monitoringUpdateRequired),
            installer: StubHelperInstaller()
        )

        manager.refreshStatus()
        while manager.status == .checking {
            await Task.yield()
        }

        XCTAssertEqual(manager.status, .monitoringUpdateRequired)
    }

    func testFailedInstallPublishesActionableError() async {
        let manager = SMARTHelperManager(
            inspector: StubSMARTHelperInspector(result: .notInstalled),
            installer: FailingSMARTHelperInstaller(message: "Authorization denied")
        )

        let installed = await manager.installOrUpdate()

        XCTAssertFalse(installed)
        XCTAssertEqual(manager.status, .installationFailed("Authorization denied"))
    }

    func testDeviceEvidenceInvalidatesOlderInspectionResult() async {
        let inspector = ControlledSMARTHelperInspector()
        let manager = SMARTHelperManager(
            inspector: inspector,
            installer: StubHelperInstaller()
        )

        manager.refreshStatus()
        await inspector.waitUntilInspectionStarts()
        manager.record(.installed)
        await inspector.finish(with: .notInstalled)
        await Task.yield()

        XCTAssertEqual(manager.status, .installed)
    }

    func testNormalEvidenceDoesNotRegressStrongerHelperStatus() {
        let manager = SMARTHelperManager(
            inspector: StubSMARTHelperInspector(result: .notInstalled),
            installer: StubHelperInstaller()
        )

        manager.record(.installed)
        manager.record(.notInstalled)
        XCTAssertEqual(manager.status, .installed)

        manager.record(.updateRequired)
        manager.record(.installed)
        XCTAssertEqual(manager.status, .updateRequired)
    }
}

@MainActor
final class SMARTPresentationTests: XCTestCase {
    func testCompanionUnavailableUsesExplicitDevicePresentationAndRepairAction() async throws {
        let device = makeDevice(id: "disk-companion", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let controller = makeController(
            smartService: StubSMARTService(refreshResult: .companionUnavailable),
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSMARTSnapshot(
            controller,
            for: device.id,
            equals: .companionUnavailable
        )

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .companionUnavailable)
        XCTAssertEqual(details.primaryAction, .updateHelper)
        XCTAssertEqual(controller.smartHelperManager.status, .companionUnavailable)
    }

    func testRefreshUsesLoadingSnapshotWhileRefreshIsInFlightIncludingRetry() async throws {
        let device = makeDevice(id: "disk6", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 1)

        let firstRefreshDetails = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(firstRefreshDetails.snapshot, .loading)
        XCTAssertTrue(firstRefreshDetails.isRefreshing)
        XCTAssertEqual(controller.state.selectedDevice?.smartSnapshot, .loading)

        await smartService.finishCurrentRefresh(with: .failed("Read failed"))
        await waitUntilSMARTPresentationSettles(controller)
        XCTAssertEqual(controller.state.selectedSMARTDetails?.snapshot, .failed("Read failed"))

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 2)

        let retryDetails = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(retryDetails.snapshot, .loading)
        XCTAssertTrue(retryDetails.isRefreshing)
        XCTAssertEqual(controller.state.selectedDevice?.smartSnapshot, .loading)
    }

    func testSelectedDevicePublishesApplicationHelperNotInstalledStatus() async throws {
        let device = makeDevice(id: "disk42", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let helperInstaller = StubHelperInstaller()
        let controller = makeController(
            smartService: StubSMARTService(
                refreshResult: .helperNotInstalled
            ),
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .helperNotInstalled)
        XCTAssertEqual(details.primaryAction, .installHelper)
        XCTAssertEqual(controller.smartHelperManager.status, .notInstalled)
        let installCallCount = await helperInstaller.installCallCount
        XCTAssertEqual(installCallCount, 0)
    }

    func testMinorCompatibilityMismatchDoesNotForceUpdate() async throws {
        let smartData = SmartData(
            overallHealth: .passed,
            primaryTemperature: 41,
            highestTemperature: 44,
            sensorTemperatures: ["Composite": 41]
        )
        let discovery = StubSMARTPresentationDeviceDiscovery(
            results: [[makeDevice(id: "disk8", smartSnapshot: .notRequested)]]
        )
        let controller = makeController(
            smartService: StubSMARTService(
                refreshResult: .available(
                    smartData,
                    compatibility: .degraded
                )
            ),
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: DeviceID(rawValue: "disk8"))

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .degraded)
        XCTAssertEqual(details.primaryAction, .refresh)
    }

    func testInstallHelperRetriesRefreshAndPublishesAvailableSMARTDetails() async throws {
        let smartData = SmartData(
            overallHealth: .passed,
            primaryTemperature: 38,
            highestTemperature: 40,
            sensorTemperatures: ["Composite": 38]
        )
        let discovery = StubSMARTPresentationDeviceDiscovery(
            results: [[makeDevice(id: "disk11", smartSnapshot: .notRequested)]]
        )
        let smartService = SequencedSMARTService(
            refreshResults: [
                .helperNotInstalled,
                .available(smartData, compatibility: .compatible)
            ]
        )
        let helperInstaller = StubHelperInstaller()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: DeviceID(rawValue: "disk11"))
        await waitUntilSMARTSnapshot(
            controller,
            for: DeviceID(rawValue: "disk11"),
            equals: .helperNotInstalled
        )
        XCTAssertEqual(controller.state.selectedSMARTDetails?.primaryAction, .installHelper)

        controller.installSMARTHelper()
        await waitUntilSMARTSnapshot(
            controller,
            for: DeviceID(rawValue: "disk11"),
            equals: .available(smartData)
        )

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .compatible)
        XCTAssertEqual(details.primaryAction, .refresh)
        XCTAssertEqual(controller.smartHelperManager.status, .installed)
        let installCallCount = await helperInstaller.installCallCount
        XCTAssertEqual(installCallCount, 1)
        let refreshedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(refreshedDevice.smartSnapshot, .available(smartData))
    }

    func testInstallSupersedesPreInstallSMARTRefresh() async throws {
        let device = makeDevice(id: "disk12", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let smartService = SupersedingSMARTService()
        let helperInstaller = StubHelperInstaller()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )
        let smartData = SmartData(overallHealth: .passed, primaryTemperature: 37)

        await discovery.resolveNextDiscovery()
        await smartService.waitUntilRefreshStarts(count: 1)

        controller.installSMARTHelper()
        await smartService.waitUntilRefreshStarts(count: 2)

        await smartService.finishRefresh(id: 0, with: .helperNotInstalled)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(controller.state.selectedSMARTDetails?.snapshot, .loading)
        XCTAssertEqual(controller.smartHelperManager.status, .installed)

        await smartService.finishRefresh(
            id: 1,
            with: .available(smartData, compatibility: .compatible)
        )
        await waitUntilSMARTSnapshot(controller, for: device.id, equals: .available(smartData))

        XCTAssertEqual(controller.smartHelperManager.status, .installed)
    }

    func testUpdateRequiredPublishesApplicationHelperStatus() async throws {
        let discovery = StubSMARTPresentationDeviceDiscovery(
            results: [[makeDevice(id: "disk13", smartSnapshot: .notRequested)]]
        )
        let helperInstaller = StubHelperInstaller()
        let controller = makeController(
            smartService: StubSMARTService(refreshResult: .updateRequired),
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: DeviceID(rawValue: "disk13"))

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .updateRequired)
        XCTAssertEqual(details.primaryAction, .updateHelper)
        XCTAssertEqual(controller.smartHelperManager.status, .updateRequired)
        let installCallCount = await helperInstaller.installCallCount
        XCTAssertEqual(installCallCount, 0)
    }

    func testRefreshResultStaysWithInitiatingDeviceAfterSelectionChanges() async throws {
        let firstDevice = makeDevice(id: "disk20", smartSnapshot: .notRequested)
        let secondDevice = makeDevice(id: "disk21", smartSnapshot: .unsupported)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[firstDevice, secondDevice]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )
        let smartData = SmartData(
            overallHealth: .passed,
            primaryTemperature: 35,
            highestTemperature: 39,
            sensorTemperatures: ["Composite": 35]
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstDevice.id)
        await smartService.waitUntilRefreshStarts(count: 1)

        controller.selectDevice(secondDevice.id)
        await waitUntilSelectedDevice(controller, equals: secondDevice.id)

        await smartService.finishCurrentRefresh(
            with: .available(smartData, compatibility: .compatible)
        )
        await waitUntilSMARTSnapshot(
            controller,
            for: firstDevice.id,
            equals: .available(smartData)
        )

        XCTAssertEqual(controller.state.selectedDeviceID, secondDevice.id)
        XCTAssertEqual(controller.state.selectedSMARTDetails?.snapshot, .unsupported)

        controller.selectDevice(firstDevice.id)
        await waitUntilSelectedDevice(controller, equals: firstDevice.id)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .compatible)
    }

    func testObservationUpdateDuringRefreshKeepsSelectedDeviceSnapshotLoading() async throws {
        let initialDevice = makeDevice(id: "disk24", smartSnapshot: .notRequested)
        let observedDevice = makeDevice(id: "disk24", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[initialDevice]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: initialDevice.id)

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 1)

        await discovery.sendObservedDevices([observedDevice])
        await Task.yield()

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .loading)
        XCTAssertTrue(details.isRefreshing)
        XCTAssertEqual(controller.state.selectedDevice?.smartSnapshot, .loading)
    }

    func testStartingRefreshClearsLastErrorWhileRetryIsInFlight() async throws {
        let device = makeDevice(id: "disk25", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let smartService = ControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 1)
        await smartService.finishCurrentRefresh(with: .failed("Read failed"))
        await waitUntilSMARTPresentationSettles(controller)

        XCTAssertEqual(controller.state.selectedSMARTDetails?.lastError, "Read failed")

        controller.refreshSelectedDeviceSMART()
        await smartService.waitUntilRefreshStarts(count: 2)

        let retryDetails = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertTrue(retryDetails.isRefreshing)
        XCTAssertNil(retryDetails.lastError)
    }

    func testStartingHelperInstallPublishesApplicationLevelFailureAndRetryState() async throws {
        let device = makeDevice(id: "disk26", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[device]])
        let helperInstaller = ControlledHelperInstaller(
            outcomes: [
                .failure("Install failed"),
                .pending
            ]
        )
        let controller = makeController(
            smartService: StubSMARTService(refreshResult: .helperNotInstalled),
            helperInstaller: helperInstaller,
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: device.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)

        controller.installSMARTHelper()
        await helperInstaller.waitUntilInstallStarts(count: 1)
        await waitUntilHelperStatus(controller, equals: .installationFailed("Install failed"))

        XCTAssertEqual(controller.smartHelperManager.status, .installationFailed("Install failed"))
        XCTAssertEqual(controller.state.selectedSMARTDetails?.snapshot, .helperNotInstalled)

        controller.installSMARTHelper()
        await helperInstaller.waitUntilInstallStarts(count: 2)

        XCTAssertEqual(controller.smartHelperManager.status, .installing)
    }

    func testRediscoveryPreservesFetchedSMARTSnapshotAndCompatibilityForSameDevice() async throws {
        let firstPassDevice = makeDevice(id: "disk30", smartSnapshot: .notRequested)
        let rediscoveredDevice = makeDevice(id: "disk30", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[firstPassDevice], [rediscoveredDevice]])
        let smartData = SmartData(
            overallHealth: .passed,
            primaryTemperature: 42,
            highestTemperature: 45,
            sensorTemperatures: ["Composite": 42]
        )
        let controller = makeController(
            smartService: StubSMARTService(
                refreshResult: .available(smartData, compatibility: .degraded)
            ),
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )

        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstPassDevice.id)

        controller.refreshSelectedDeviceSMART()
        await waitUntilSMARTPresentationSettles(controller)
        XCTAssertEqual(controller.state.selectedSMARTDetails?.compatibility, .degraded)

        controller.refresh()
        await discovery.resolveNextDiscovery()
        await waitUntilSelectedDevice(controller, equals: firstPassDevice.id)

        let details = try XCTUnwrap(controller.state.selectedSMARTDetails)
        XCTAssertEqual(details.snapshot, .available(smartData))
        XCTAssertEqual(details.compatibility, .degraded)
        let selectedDevice = try XCTUnwrap(controller.state.selectedDevice)
        XCTAssertEqual(selectedDevice.smartSnapshot, .available(smartData))
    }

    func testInitialConcurrentSMARTRefreshesStayBoundToTheirDevices() async throws {
        let firstDevice = makeDevice(id: "disk40", smartSnapshot: .notRequested)
        let secondDevice = makeDevice(id: "disk41", smartSnapshot: .notRequested)
        let discovery = StubSMARTPresentationDeviceDiscovery(results: [[firstDevice, secondDevice]])
        let smartService = MultiDeviceControlledSMARTService()
        let controller = makeController(
            smartService: smartService,
            helperInstaller: StubHelperInstaller(),
            deviceDiscovery: discovery
        )
        let firstData = SmartData(overallHealth: .passed, primaryTemperature: 36)
        let secondData = SmartData(overallHealth: .passed, primaryTemperature: 41)

        await discovery.resolveNextDiscovery()
        await smartService.waitUntilRefreshStarts(for: "disk40")
        await smartService.waitUntilRefreshStarts(for: "disk41")

        await smartService.finishRefresh(
            for: "disk41",
            with: .available(secondData, compatibility: .compatible)
        )
        await waitUntilSMARTSnapshot(
            controller,
            for: secondDevice.id,
            equals: .available(secondData)
        )

        let deviceAfterSecondFinish = try XCTUnwrap(
            controller.state.devices.first(where: { $0.id == secondDevice.id })
        )
        XCTAssertEqual(deviceAfterSecondFinish.smartSnapshot, .available(secondData))
        XCTAssertEqual(
            controller.state.devices.first(where: { $0.id == firstDevice.id })?.smartSnapshot,
            .loading
        )

        await smartService.finishRefresh(
            for: "disk40",
            with: .available(firstData, compatibility: .degraded)
        )
        await waitUntilSMARTSnapshot(
            controller,
            for: firstDevice.id,
            equals: .available(firstData)
        )

        let firstDetails = controller.state.smartDetails(for: firstDevice.id)
        let secondDetails = controller.state.smartDetails(for: secondDevice.id)
        XCTAssertEqual(firstDetails?.snapshot, .available(firstData))
        XCTAssertEqual(firstDetails?.compatibility, .degraded)
        XCTAssertEqual(secondDetails?.snapshot, .available(secondData))
        XCTAssertEqual(secondDetails?.compatibility, .compatible)
    }

    private func makeDevice(id rawID: String, smartSnapshot: SmartSnapshot) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: rawID),
            displayName: "Device \(rawID)",
            transportName: "USB",
            smartSnapshot: smartSnapshot,
            sessionMetrics: .empty(),
            physicalStoreBSDName: rawID,
            apfsContainerBSDName: nil,
            volumes: [MountedVolume(bsdName: "\(rawID)s1")]
        )
    }

    private func makeController(
        smartService: any SMARTServiceProviding,
        helperInstaller: any HelperInstalling,
        deviceDiscovery: any ExternalDeviceDiscovering
    ) -> PalmosAppController {
        let helperManager = SMARTHelperManager(
            inspector: StubSMARTHelperInspector(result: .installed),
            installer: helperInstaller
        )
        return PalmosAppController(
            smartService: smartService,
            smartHelperManager: helperManager,
            deviceDiscovery: deviceDiscovery,
            systemProfilerProvider: StubSMARTSystemProfilerProvider(),
            diskUtilAPFSProvider: StubSMARTDiskUtilAPFSProvider()
        )
    }

    private func waitUntilSelectedDevice(
        _ controller: PalmosAppController,
        equals id: DeviceID
    ) async {
        while controller.state.selectedDeviceID != id {
            await Task.yield()
        }
    }

    private func waitUntilSMARTPresentationSettles(_ controller: PalmosAppController) async {
        while controller.state.selectedSMARTDetails?.isRefreshing == true {
            await Task.yield()
        }
    }

    private func waitUntilHelperStatus(
        _ controller: PalmosAppController,
        equals expectedStatus: SMARTHelperStatus
    ) async {
        while controller.smartHelperManager.status != expectedStatus {
            await Task.yield()
        }
    }

    private func waitUntilSMARTSnapshot(
        _ controller: PalmosAppController,
        for deviceID: DeviceID,
        equals expectedSnapshot: SmartSnapshot
    ) async {
        while controller.state.smartDetails(for: deviceID)?.snapshot != expectedSnapshot {
            await Task.yield()
        }
    }
}

private actor StubSMARTService: SMARTServiceProviding {
    let refreshResult: SMARTServiceRefreshResult

    init(refreshResult: SMARTServiceRefreshResult) {
        self.refreshResult = refreshResult
    }

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        _ = device
        return refreshResult
    }
}

private actor SequencedSMARTService: SMARTServiceProviding {
    private let refreshResults: [SMARTServiceRefreshResult]
    private var invocationCount = 0

    init(refreshResults: [SMARTServiceRefreshResult]) {
        self.refreshResults = refreshResults
    }

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        _ = device
        let index = min(invocationCount, refreshResults.count - 1)
        invocationCount += 1
        return refreshResults[index]
    }
}

private actor SupersedingSMARTService: SMARTServiceProviding {
    private var nextRefreshID = 0
    private var continuations: [Int: CheckedContinuation<SMARTServiceRefreshResult, Never>] = [:]

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        _ = device
        let refreshID = nextRefreshID
        nextRefreshID += 1
        return await withCheckedContinuation { continuation in
            continuations[refreshID] = continuation
        }
    }

    func waitUntilRefreshStarts(count: Int) async {
        while nextRefreshID < count {
            await Task.yield()
        }
    }

    func finishRefresh(id: Int, with result: SMARTServiceRefreshResult) async {
        while continuations[id] == nil {
            await Task.yield()
        }
        continuations.removeValue(forKey: id)?.resume(returning: result)
    }
}

private actor ControlledSMARTService: SMARTServiceProviding {
    private var pendingContinuation: CheckedContinuation<SMARTServiceRefreshResult, Never>?
    private var refreshStartCount = 0

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        _ = device
        refreshStartCount += 1
        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func waitUntilRefreshStarts(count expectedCount: Int) async {
        while refreshStartCount < expectedCount {
            await Task.yield()
        }
    }

    func finishCurrentRefresh(with result: SMARTServiceRefreshResult) async {
        while pendingContinuation == nil {
            await Task.yield()
        }

        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(returning: result)
    }
}

private actor MultiDeviceControlledSMARTService: SMARTServiceProviding {
    private var pendingContinuations: [String: CheckedContinuation<SMARTServiceRefreshResult, Never>] = [:]
    private var refreshStartCounts: [String: Int] = [:]

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        refreshStartCounts[device.physicalStoreBSDName, default: 0] += 1
        return await withCheckedContinuation { continuation in
            pendingContinuations[device.physicalStoreBSDName] = continuation
        }
    }

    func waitUntilRefreshStarts(for bsdName: String, count expectedCount: Int = 1) async {
        while refreshStartCounts[bsdName, default: 0] < expectedCount {
            await Task.yield()
        }
    }

    func finishRefresh(for bsdName: String, with result: SMARTServiceRefreshResult) async {
        while pendingContinuations[bsdName] == nil {
            await Task.yield()
        }

        let continuation = pendingContinuations.removeValue(forKey: bsdName)
        continuation?.resume(returning: result)
    }
}

private final class StubSMARTSystemProfilerProvider: SystemProfilerProviding, @unchecked Sendable {
    func fetchIfNeeded() async {}
    func refresh() async {}
    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? { nil }
    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? { nil }
    func thunderboltInfo() -> ThunderboltInfo? { nil }
}

private final class StubSMARTDiskUtilAPFSProvider: DiskUtilAPFSProviding, @unchecked Sendable {
    func refresh() async {}
    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo? { nil }
    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo] { [] }
}

private actor StubSMARTHelperInspector: SMARTHelperInspecting {
    let result: SMARTHelperInspection

    init(result: SMARTHelperInspection) {
        self.result = result
    }

    func inspectSMARTHelper() async -> SMARTHelperInspection {
        result
    }
}

private actor ControlledSMARTHelperInspector: SMARTHelperInspecting {
    private var continuation: CheckedContinuation<SMARTHelperInspection, Never>?
    private var didStart = false

    func inspectSMARTHelper() async -> SMARTHelperInspection {
        didStart = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilInspectionStarts() async {
        while didStart == false {
            await Task.yield()
        }
    }

    func finish(with result: SMARTHelperInspection) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor FailingSMARTHelperInstaller: HelperInstalling {
    let message: String

    init(message: String) {
        self.message = message
    }

    func install() async throws {
        throw NSError(
            domain: "PalmosTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private actor StubHelperInstaller: HelperInstalling {
    private(set) var installCallCount = 0

    func install() async throws {
        installCallCount += 1
    }
}

private actor ControlledHelperInstaller: HelperInstalling {
    enum Outcome {
        case failure(String)
        case pending
    }

    private let outcomes: [Outcome]
    private var invocationCount = 0
    private var pendingContinuation: CheckedContinuation<Void, Error>?

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func install() async throws {
        let index = min(invocationCount, outcomes.count - 1)
        let outcome = outcomes[index]
        invocationCount += 1

        switch outcome {
        case let .failure(message):
            throw NSError(
                domain: "PalmosTests",
                code: invocationCount,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        case .pending:
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
            }
        }
    }

    func waitUntilInstallStarts(count expectedCount: Int) async {
        while invocationCount < expectedCount {
            await Task.yield()
        }
    }
}

private final class StubSMARTPresentationDeviceDiscovery: ExternalDeviceDiscovering, @unchecked Sendable {
    private let state: State

    init(results: [[ExternalDevice]]) {
        self.state = State(results: results)
    }

    func discoverDevices() async -> [ExternalDevice] {
        await state.discoverDevices()
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor @Sendable ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        Task {
            await state.setObservation(onUpdate)
        }
        return StubSMARTPresentationDeviceObservation()
    }

    func observeDiskEjectIntents(
        _ onIntent: @escaping @MainActor @Sendable (DiskEjectIntent) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        _ = onIntent
        return StubSMARTPresentationDeviceObservation()
    }

    func resolveNextDiscovery() async {
        await state.resolveNextDiscovery()
    }

    func sendObservedDevices(_ devices: [ExternalDevice]) async {
        await state.sendObservedDevices(devices)
    }

    private actor State {
        private let results: [[ExternalDevice]]
        private var invocationCount = 0
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
        private var observation: (@MainActor @Sendable ([ExternalDevice]) -> Void)?

        init(results: [[ExternalDevice]]) {
            self.results = results
        }

        func discoverDevices() async -> [ExternalDevice] {
            await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }

            defer { invocationCount += 1 }

            let index = min(invocationCount, results.count - 1)
            return results[index]
        }

        func resolveNextDiscovery() async {
            while pendingContinuations.isEmpty {
                await Task.yield()
            }

            let continuation = pendingContinuations.removeFirst()
            continuation.resume()
        }

        func setObservation(_ observation: @escaping @MainActor @Sendable ([ExternalDevice]) -> Void) {
            self.observation = observation
        }

        func sendObservedDevices(_ devices: [ExternalDevice]) async {
            while observation == nil {
                await Task.yield()
            }

            await observation?(devices)
        }
    }
}

private struct StubSMARTPresentationDeviceObservation: ExternalDeviceDiscoveryObservation {
    func cancel() {}
}

private func makeAppSettings(temperatureUnit: TemperatureUnit) -> AppSettings {
    let suiteName = "PalmosTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(temperatureUnit.rawValue, forKey: AppSettings.temperatureUnitDefaultsKey)
    return AppSettings(defaults: defaults)
}
