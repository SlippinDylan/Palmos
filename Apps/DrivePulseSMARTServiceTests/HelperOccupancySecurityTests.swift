import Darwin
import Foundation
import Security
import XCTest

final class HelperOccupancySecurityTests: XCTestCase {
    func testSMARTXPCSelectorNamesRemainByteStable() {
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.fetchHelperHandshake(withReply:))),
            "fetchHelperHandshakeWithReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.readSMARTData(for:withReply:))),
            "readSMARTDataFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.readSMARTDataWithCompletion(for:withReply:))),
            "readSMARTDataWithCompletionFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.cancelSMARTData(for:))),
            "cancelSMARTDataFor:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.cancelSMARTDataRequest(for:withReply:))),
            "cancelSMARTDataRequestFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.installSmartctlCompanion(for:withReply:))),
            "installSmartctlCompanionFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.scanDiskOccupancy(for:withReply:))),
            "scanDiskOccupancyFor:withReply:"
        )
    }

    func testMinorSixNegotiatesObservableSMARTFailures() {
        XCTAssertFalse(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 5).observableSMARTFailures
        )
        XCTAssertTrue(
            XPCFeatureCapabilities.negotiated(helperContractMinor: 6).observableSMARTFailures
        )
    }

    func testSmartctlRunnerTimeoutKillsTERMResistantProcessBeforeReturning() async throws {
        let fixture = try makeExecutableFixture(body: termResistantFixtureBody)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = SmartctlRunner(executableLocator: { fixture.executable })
        let start = ContinuousClock.now
        let task = Task {
            try await runner.readSMARTData(
                for: "disk4",
                transportHint: .none,
                timeout: .seconds(1)
            )
        }
        let pid = try await readFixturePID(at: fixture.pidFile)

        do {
            _ = try await task.value
            XCTFail("Expected timeout")
        } catch let error as SmartctlRunner.RunnerError {
            XCTAssertEqual(error, .timedOut)
        }

        XCTAssertFalse(processExists(pid))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSmartctlRunnerCancellationKillsTERMResistantProcessBeforeReturning() async throws {
        let fixture = try makeExecutableFixture(body: termResistantFixtureBody)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = SmartctlRunner(executableLocator: { fixture.executable })
        let task = Task {
            try await runner.readSMARTData(for: "disk4", transportHint: .none)
        }
        let pid = try await readFixturePID(at: fixture.pidFile)
        let start = ContinuousClock.now

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(processExists(pid))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSmartctlRunnerDrainsOversizedStdoutAndStderrWithoutDeadlock() async throws {
        let fixture = try makeExecutableFixture { _ in
            """
            /usr/bin/yes stdout | /usr/bin/head -c 2200000
            /usr/bin/yes stderr | /usr/bin/head -c 100000 >&2
            """
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = SmartctlRunner(executableLocator: { fixture.executable })
        let start = ContinuousClock.now

        do {
            _ = try await runner.readSMARTData(for: "disk4", transportHint: .none)
            XCTFail("Expected bounded output rejection")
        } catch let error as SmartctlRunner.RunnerError {
            XCTAssertEqual(error, .outputTooLarge)
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testCancellationWhileExecutableLookupIsPendingDoesNotLaunchProcess() async throws {
        let fixture = try makeExecutableFixture(body: termResistantFixtureBody)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let enteredLocator = DispatchSemaphore(value: 0)
        let releaseLocator = DispatchSemaphore(value: 0)
        let runner = SmartctlRunner(executableLocator: {
            enteredLocator.signal()
            releaseLocator.wait()
            return fixture.executable
        })
        let task = Task {
            try await runner.readSMARTData(
                for: "disk4",
                transportHint: .none,
                timeout: .milliseconds(200)
            )
        }
        XCTAssertEqual(enteredLocator.wait(timeout: .now() + 1), .success)

        task.cancel()
        releaseLocator.signal()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pidFile.path))
    }

    func testCompletionAwareSMARTReturnsBoundedBusinessErrorEnvelopes() async throws {
        let cases: [(SmartctlRunner.RunnerError, SMARTReadCompletionErrorCode)] = [
            (.executableUnavailable, .executableUnavailable),
            (.timedOut, .timedOut),
            (.commandFailed(exitCode: 2, transportHint: .none, output: String(repeating: "x", count: 64_000)), .commandFailed),
        ]

        for (runnerError, expectedCode) in cases {
            let service = DrivePulseSMARTService(runner: FixtureSMARTDataRunner(result: .failure(runnerError)))
            let requestID = UUID()
            let reply = await Self.completionReply(
                from: service,
                request: SMARTReadRequest(
                    physicalDeviceBSDName: "disk4",
                    deviceProtocol: nil,
                    deviceModel: nil,
                    requestID: requestID.uuidString
                )
            )
            XCTAssertNil(reply.error)
            let replyData = try XCTUnwrap(reply.data)
            let response = try DrivePulseXPCMessages.decodeSMARTReadCompletionResponse(from: replyData)
            XCTAssertEqual(response.requestID, requestID.uuidString)
            XCTAssertEqual(response.error?.code, expectedCode)
            XCTAssertTrue(response.processDidExit)
            XCTAssertEqual(response.deviceSMARTIOQuiesced, true)
            XCTAssertTrue(response.payload.isEmpty)
            XCTAssertLessThanOrEqual(replyData.count, SMARTXPCLimits.responseBytes)
            XCTAssertLessThanOrEqual(response.error?.message.utf8.count ?? 0, SMARTXPCLimits.errorMessageUTF8Bytes)
        }
    }

    func testCompletionAwareSMARTQuiescenceDistinguishesAdmittedAndRejectedRequests() async throws {
        let payload = Data(#"{"smart_status":{"passed":true}}"#.utf8)
        let successService = DrivePulseSMARTService(
            runner: FixtureSMARTDataRunner(result: .success(payload))
        )
        let success = try completionResponse(await Self.completionReply(
            from: successService,
            request: Self.smartRequest("disk4", requestID: UUID())
        ))
        XCTAssertEqual(success.payload, payload)
        XCTAssertEqual(success.deviceSMARTIOQuiesced, true)

        let invalid = await withCheckedContinuation { continuation in
            successService.readSMARTDataWithCompletion(for: Data("not-json".utf8)) { data, error in
                continuation.resume(returning: (data, error))
            }
        }
        let invalidResponse = try completionResponse(invalid)
        XCTAssertEqual(invalidResponse.error?.code, .invalidRequest)
        XCTAssertEqual(invalidResponse.deviceSMARTIOQuiesced, false)

        let legacySchemaOne = Data(
            #"{"schemaVersion":1,"payload":"","processDidExit":true}"#.utf8
        )
        let decodedLegacy = try DrivePulseXPCMessages.decodeSMARTReadCompletionResponse(
            from: legacySchemaOne
        )
        XCTAssertNil(decodedLegacy.deviceSMARTIOQuiesced)

        let invalidQuiescence = SMARTReadCompletionResponse(
            schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
            payload: Data(),
            processDidExit: false,
            deviceSMARTIOQuiesced: true
        )
        XCTAssertThrowsError(
            try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(invalidQuiescence)
        )
    }

    func testSMARTCoordinatorRejectsDuplicatePerDeviceAndGlobalPressure() async throws {
        let runner = BlockingSMARTDataRunner()
        let service = DrivePulseSMARTService(
            runner: runner,
            maxConcurrentSMARTRequests: 2,
            maxConcurrentSMARTRequestsPerDevice: 1
        )
        let firstID = UUID()
        let firstRequest = Self.smartRequest("disk4", requestID: firstID)
        let first = SMARTReplyProbe()
        first.start(service: service, request: firstRequest)
        await runner.waitUntilStarted(count: 1)

        let duplicate = await Self.completionReply(
            from: service,
            request: Self.smartRequest("disk5", requestID: firstID)
        )
        let duplicateResponse = try completionResponse(duplicate)
        XCTAssertEqual(duplicateResponse.error?.code, .duplicateRequest)
        XCTAssertEqual(duplicateResponse.deviceSMARTIOQuiesced, false)

        let sameDevice = await Self.completionReply(
            from: service,
            request: Self.smartRequest("disk4", requestID: UUID())
        )
        let sameDeviceResponse = try completionResponse(sameDevice)
        XCTAssertEqual(sameDeviceResponse.error?.code, .busy)
        XCTAssertEqual(sameDeviceResponse.deviceSMARTIOQuiesced, false)

        let secondRequest = Self.smartRequest("disk5", requestID: UUID())
        let second = SMARTReplyProbe()
        second.start(service: service, request: secondRequest)
        await runner.waitUntilStarted(count: 2)
        let globalPressure = await Self.completionReply(
            from: service,
            request: Self.smartRequest("disk6", requestID: UUID())
        )
        let globalPressureResponse = try completionResponse(globalPressure)
        XCTAssertEqual(globalPressureResponse.error?.code, .busy)
        XCTAssertEqual(globalPressureResponse.deviceSMARTIOQuiesced, false)

        await runner.releaseAll()
        _ = await first.value()
        _ = await second.value()
    }

    func testBoundedSMARTCancellationAcknowledgesAndCompletionObservesExit() async throws {
        let runner = BlockingSMARTDataRunner()
        let service = DrivePulseSMARTService(runner: runner)
        let requestID = UUID()
        let request = Self.smartRequest("disk4", requestID: requestID)
        let completion = SMARTReplyProbe()
        completion.start(service: service, request: request)
        await runner.waitUntilStarted(count: 1)

        let cancelData = try DrivePulseXPCMessages.encodeSMARTCancelRequest(
            SMARTCancelRequest(requestID: requestID.uuidString)
        )
        service.cancelSMARTData(for: String(repeating: "x", count: SMARTXPCLimits.legacyCancelRequestUTF8Bytes + 1))
        let legacyCancellationObserved = await runner.cancellationWasObserved()
        XCTAssertFalse(legacyCancellationObserved)
        let acknowledgement = await cancelReply(from: service, requestData: cancelData)
        XCTAssertNil(acknowledgement.error)
        let decodedAcknowledgement = try DrivePulseXPCMessages.decodeSMARTCancelAcknowledgement(
            from: try XCTUnwrap(acknowledgement.data)
        )
        XCTAssertEqual(decodedAcknowledgement.requestID, requestID.uuidString.lowercased())
        XCTAssertEqual(decodedAcknowledgement.result, .accepted)

        let response = try completionResponse(await completion.value())
        XCTAssertEqual(response.error?.code, .cancelled)
        XCTAssertTrue(response.processDidExit)
        XCTAssertEqual(response.deviceSMARTIOQuiesced, true)

        XCTAssertThrowsError(
            try DrivePulseXPCMessages.decodeSMARTCancelRequest(
                from: Data(repeating: 0, count: SMARTXPCLimits.cancelRequestBytes + 1)
            )
        )
    }

    func testLegacyMinorFiveCancellationTerminatesTaskAndReleasesAdmission() async throws {
        let runner = BlockingSMARTDataRunner()
        let service = DrivePulseSMARTService(
            runner: runner,
            maxConcurrentSMARTRequests: 1,
            maxConcurrentSMARTRequestsPerDevice: 1
        )
        let requestID = UUID()
        let first = SMARTReplyProbe()
        first.startLegacy(
            service: service,
            request: Self.smartRequest("disk4", requestID: requestID)
        )
        await runner.waitUntilStarted(count: 1)

        service.cancelSMARTData(for: requestID.uuidString)
        let cancelled = await first.value()
        XCTAssertNil(cancelled.data)
        XCTAssertNotNil(cancelled.error)
        let cancellationWasObserved = await runner.cancellationWasObserved()
        XCTAssertTrue(cancellationWasObserved)

        await Task.yield()
        let followup = SMARTReplyProbe()
        followup.startLegacy(
            service: service,
            request: Self.smartRequest("disk5", requestID: UUID())
        )
        await runner.releaseAll()
        let followupReply = await followup.value()
        XCTAssertNil(followupReply.error)
        XCTAssertEqual(
            followupReply.data,
            Data(#"{"smart_status":{"passed":true}}"#.utf8)
        )
    }

    func testLegacySMARTReadUsesRawReplyAndBoundedAdmission() async throws {
        let runner = BlockingSMARTDataRunner()
        let service = DrivePulseSMARTService(
            runner: runner,
            maxConcurrentSMARTRequests: 1,
            maxConcurrentSMARTRequestsPerDevice: 1
        )
        let requestID = UUID()
        let admitted = SMARTReplyProbe()
        admitted.startLegacy(
            service: service,
            request: Self.smartRequest("disk4", requestID: requestID)
        )
        await runner.waitUntilStarted(count: 1)

        let duplicate = SMARTReplyProbe()
        duplicate.startLegacy(
            service: service,
            request: Self.smartRequest("disk5", requestID: requestID)
        )
        let duplicateReply = await duplicate.value()
        XCTAssertNil(duplicateReply.data)
        XCTAssertNotNil(duplicateReply.error)

        let pressure = SMARTReplyProbe()
        pressure.startLegacy(
            service: service,
            request: Self.smartRequest("disk5", requestID: UUID())
        )
        let pressureReply = await pressure.value()
        XCTAssertNil(pressureReply.data)
        XCTAssertNotNil(pressureReply.error)
        let startedCount = await runner.startedCount()
        XCTAssertEqual(startedCount, 1)

        await runner.releaseAll()
        let admittedReply = await admitted.value()
        XCTAssertNil(admittedReply.error)
        XCTAssertEqual(
            admittedReply.data,
            Data(#"{"smart_status":{"passed":true}}"#.utf8)
        )
    }

    func testMissingCompanionMapsFileNotFoundToExecutableUnavailable() async {
        let runner = SmartctlRunner(executableLocator: {
            throw CocoaError(.fileNoSuchFile)
        })
        do {
            _ = try await runner.readSMARTData(for: "disk4", transportHint: .none)
            XCTFail("Expected trusted companion to be unavailable")
        } catch let error as SmartctlRunner.RunnerError {
            XCTAssertEqual(error, .executableUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHandshakeReportsCompanionCapability() async throws {
        let unavailable = DrivePulseSMARTService(
            runner: FixtureSMARTDataRunner(result: .failure(SmartctlRunner.RunnerError.executableUnavailable), companionAvailable: false)
        )
        let reply = await handshakeReply(from: unavailable)
        let handshake = try DrivePulseXPCMessages.decode(
            HelperHandshake.self,
            from: try XCTUnwrap(reply.data)
        )
        XCTAssertEqual(handshake.contractMinor, XPCContractVersion.currentMinor)
        XCTAssertEqual(handshake.smartctlCompanionAvailable, false)
    }

    func testSMARTRequestAndPayloadLimitsRejectOversizedMessages() throws {
        let oversizedRequest = SMARTReadRequest(
            physicalDeviceBSDName: "disk4",
            deviceProtocol: nil,
            deviceModel: String(repeating: "x", count: SMARTXPCLimits.requestBytes)
        )
        XCTAssertThrowsError(try DrivePulseXPCMessages.encodeSMARTReadRequest(oversizedRequest))

        let invalidRequestID = SMARTReadRequest(
            physicalDeviceBSDName: "disk4",
            deviceProtocol: nil,
            deviceModel: nil,
            requestID: "not-a-uuid"
        )
        XCTAssertThrowsError(try DrivePulseXPCMessages.encodeSMARTReadRequest(invalidRequestID))

        let oversizedPayload = Data(repeating: 0, count: SMARTXPCLimits.payloadBytes + 1)
        let response = SMARTReadCompletionResponse(
            schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
            payload: oversizedPayload,
            processDidExit: true
        )
        XCTAssertThrowsError(try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(response))
        XCTAssertThrowsError(try DrivePulseXPCMessages.decodeSMARTReadCompletionResponse(from: oversizedPayload))
    }

    func testSMARTCompanionInstallMessagesAreBoundedAndSchemaChecked() throws {
        let binary = Data([0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3])
        let request = SMARTCompanionInstallRequest(binary: binary)
        let encoded = try DrivePulseXPCMessages.encodeSMARTCompanionInstallRequest(request)
        XCTAssertEqual(
            try DrivePulseXPCMessages.decodeSMARTCompanionInstallRequest(from: encoded),
            request
        )

        XCTAssertThrowsError(
            try DrivePulseXPCMessages.encodeSMARTCompanionInstallRequest(
                .init(binary: Data())
            )
        )
        XCTAssertThrowsError(
            try DrivePulseXPCMessages.encodeSMARTCompanionInstallRequest(
                .init(binary: Data(repeating: 0, count: SMARTCompanionXPCLimits.binaryBytes + 1))
            )
        )
        XCTAssertThrowsError(
            try DrivePulseXPCMessages.decodeSMARTCompanionInstallRequest(
                from: Data(repeating: 0, count: SMARTCompanionXPCLimits.requestBytes + 1)
            )
        )

        let acknowledgement = SMARTCompanionInstallAcknowledgement(
            schemaVersion: SMARTCompanionInstallAcknowledgement.currentSchemaVersion,
            result: .installed
        )
        let acknowledgementData = try DrivePulseXPCMessages.encodeSMARTCompanionInstallAcknowledgement(
            acknowledgement
        )
        XCTAssertEqual(
            try DrivePulseXPCMessages.decodeSMARTCompanionInstallAcknowledgement(from: acknowledgementData),
            acknowledgement
        )
    }

    func testSMARTCompanionDigestIsLowercaseAndStable() {
        let data = Data("DrivePulse".utf8)
        XCTAssertEqual(
            SecuritySMARTCompanionCodeValidator.sha256Hex(data),
            "562189d0ad5735298956f7a22f006f4497be4df036c6f4c841910142f908fcca"
        )
        XCTAssertTrue(
            SecuritySMARTCompanionCodeValidator.isValidSHA256(
                String(repeating: "a", count: 64)
            )
        )
        XCTAssertFalse(
            SecuritySMARTCompanionCodeValidator.isValidSHA256(
                String(repeating: "A", count: 64)
            )
        )
    }

    func testCompanionInstallEndpointPassesOnlyBoundedBinaryAndAcknowledges() async throws {
        let installer = FixtureCompanionInstaller()
        let service = DrivePulseSMARTService(
            runner: FixtureSMARTDataRunner(result: .failure(.executableUnavailable)),
            companionInstaller: installer
        )
        let binary = Data([0xcf, 0xfa, 0xed, 0xfe, 0x01])
        let requestData = try DrivePulseXPCMessages.encodeSMARTCompanionInstallRequest(
            .init(binary: binary)
        )
        let reply = await companionInstallReply(from: service, requestData: requestData)
        XCTAssertNil(reply.error)
        let acknowledgement = try DrivePulseXPCMessages.decodeSMARTCompanionInstallAcknowledgement(
            from: XCTUnwrap(reply.data)
        )
        XCTAssertEqual(acknowledgement.result, .installed)
        XCTAssertEqual(installer.binary, binary)
    }

    func testCompanionInstallerAtomicallyReplacesExistingExecutableWithMode0755() throws {
        let fixture = try makeCompanionInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("old".utf8).write(to: fixture.destination)
        let binary = testMachOBinary(payload: Data("new".utf8))
        let installer = SmartctlCompanionInstaller(
            destinationURL: fixture.destination,
            validator: FixtureCompanionValidator(),
            ownerID: getuid(),
            groupID: getgid()
        )

        try installer.install(binary: binary)

        XCTAssertEqual(try Data(contentsOf: fixture.destination), binary)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.destination.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path),
            [fixture.destination.lastPathComponent]
        )
    }

    func testCompanionInstallerValidationFailurePreservesExistingExecutableAndCleansStage() throws {
        let fixture = try makeCompanionInstallFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let existing = Data("trusted-old".utf8)
        try existing.write(to: fixture.destination)
        let installer = SmartctlCompanionInstaller(
            destinationURL: fixture.destination,
            validator: FixtureCompanionValidator(error: .digestMismatch),
            ownerID: getuid(),
            groupID: getgid()
        )

        XCTAssertThrowsError(try installer.install(binary: testMachOBinary())) { error in
            XCTAssertEqual(error as? SMARTCompanionInstallerError, .digestMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), existing)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path),
            [fixture.destination.lastPathComponent]
        )
    }

    func testCompanionInstallerRejectsWritableOrSymlinkDestinationDirectory() throws {
        let writableFixture = try makeCompanionInstallFixture()
        defer { try? FileManager.default.removeItem(at: writableFixture.directory) }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o777)],
            ofItemAtPath: writableFixture.directory.path
        )
        let writableInstaller = SmartctlCompanionInstaller(
            destinationURL: writableFixture.destination,
            validator: FixtureCompanionValidator(),
            ownerID: getuid(),
            groupID: getgid()
        )
        XCTAssertThrowsError(try writableInstaller.install(binary: testMachOBinary())) { error in
            XCTAssertEqual(error as? SMARTCompanionInstallerError, .insecureDestinationDirectory)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrivePulseCompanionSymlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )
        let symlinkInstaller = SmartctlCompanionInstaller(
            destinationURL: linkedDirectory.appendingPathComponent("smartctl"),
            validator: FixtureCompanionValidator(),
            ownerID: getuid(),
            groupID: getgid()
        )
        XCTAssertThrowsError(try symlinkInstaller.install(binary: testMachOBinary())) { error in
            XCTAssertEqual(error as? SMARTCompanionInstallerError, .insecureDestinationDirectory)
        }
    }

    func testCompanionSigningRelationshipRejectsAdHocIdentifierAndTeamMismatches() {
        let helper = SMARTCompanionSigningIdentity(
            identifier: "com.drivepulse.smartservice",
            teamIdentifier: "TEAM",
            isAdHoc: false
        )
        let validCompanion = SMARTCompanionSigningIdentity(
            identifier: SmartctlRunner.trustedExecutableIdentifier,
            teamIdentifier: "TEAM",
            isAdHoc: false
        )
        XCTAssertNoThrow(
            try SecuritySMARTCompanionCodeValidator.validateSigningRelationship(
                helper: helper,
                companion: validCompanion
            )
        )

        for (companion, expectedError) in [
            (
                SMARTCompanionSigningIdentity(
                    identifier: SmartctlRunner.trustedExecutableIdentifier,
                    teamIdentifier: nil,
                    isAdHoc: true
                ),
                SMARTCompanionInstallerError.invalidCodeSignature(errSecCSUnsigned)
            ),
            (
                SMARTCompanionSigningIdentity(
                    identifier: "com.example.smartctl",
                    teamIdentifier: "TEAM",
                    isAdHoc: false
                ),
                SMARTCompanionInstallerError.unexpectedSigningIdentifier
            ),
            (
                SMARTCompanionSigningIdentity(
                    identifier: SmartctlRunner.trustedExecutableIdentifier,
                    teamIdentifier: "OTHER",
                    isAdHoc: false
                ),
                SMARTCompanionInstallerError.signingTeamMismatch
            )
        ] {
            XCTAssertThrowsError(
                try SecuritySMARTCompanionCodeValidator.validateSigningRelationship(
                    helper: helper,
                    companion: companion
                )
            ) { error in
                XCTAssertEqual(error as? SMARTCompanionInstallerError, expectedError)
            }
        }
    }

    func testCompanionInstallEndpointRejectsConcurrentRequestAndReleasesGate() async throws {
        let installer = BlockingCompanionInstaller()
        let service = DrivePulseSMARTService(
            runner: FixtureSMARTDataRunner(result: .failure(.executableUnavailable)),
            companionInstaller: installer
        )
        let requestData = try DrivePulseXPCMessages.encodeSMARTCompanionInstallRequest(
            .init(binary: testMachOBinary())
        )
        async let first = companionInstallReply(from: service, requestData: requestData)
        await installer.waitUntilStarted()

        let concurrent = await companionInstallReply(from: service, requestData: requestData)
        XCTAssertNil(concurrent.data)
        XCTAssertEqual(
            concurrent.error?.localizedDescription,
            "The SMART helper is at its bounded concurrency limit."
        )

        installer.release()
        let firstReply = await first
        XCTAssertNil(firstReply.error)

        let afterRelease = await companionInstallReply(from: service, requestData: requestData)
        XCTAssertNil(afterRelease.error)
        XCTAssertEqual(installer.installCount, 2)
    }

    func testSmartctlRunnerRejectsUnsafeExecutableAndInvalidDevice() async {
        let runner = SmartctlRunner(executableLocator: {
            throw SmartctlRunner.RunnerError.executableUnavailable
        })
        do {
            _ = try await runner.readSMARTData(for: "disk4s1", transportHint: .none)
            XCTFail("Expected invalid BSD name")
        } catch let error as SmartctlRunner.RunnerError {
            XCTAssertEqual(error, .invalidDeviceName("disk4s1"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await runner.readSMARTData(for: "disk4", transportHint: .none)
            XCTFail("Expected unavailable executable")
        } catch let error as SmartctlRunner.RunnerError {
            XCTAssertEqual(error, .executableUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeExecutableFixture(
        body: (URL) -> String
    ) throws -> SmartctlExecutableFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrivePulseSmartctlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let executable = directory.appendingPathComponent("smartctl-fixture")
        let pidFile = executable.appendingPathExtension("pid")
        let script = "#!/bin/sh\n\(body(pidFile))\n"
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )
        return SmartctlExecutableFixture(
            directory: directory,
            executable: executable,
            pidFile: pidFile
        )
    }

    private func makeCompanionInstallFixture() throws -> (
        directory: URL,
        destination: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrivePulseCompanionInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: directory.path
        )
        return (directory, directory.appendingPathComponent("smartctl"))
    }

    private func testMachOBinary(payload: Data = Data()) -> Data {
        var magic = UInt32(MH_MAGIC_64)
        var data = withUnsafeBytes(of: &magic) { Data($0) }
        data.append(payload)
        return data
    }

    private func termResistantFixtureBody(pidFile: URL) -> String {
        """
        echo $$ > '\(pidFile.path)'
        trap '' TERM
        while :; do :; done
        """
    }

    private func readFixturePID(at url: URL) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func processExists(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func smartRequest(_ disk: String, requestID: UUID) -> SMARTReadRequest {
        SMARTReadRequest(
            physicalDeviceBSDName: disk,
            deviceProtocol: nil,
            deviceModel: nil,
            requestID: requestID.uuidString
        )
    }

    private static func completionReply(
        from service: DrivePulseSMARTService,
        request: SMARTReadRequest
    ) async -> (data: Data?, error: NSError?) {
        let requestData = try! DrivePulseXPCMessages.encodeSMARTReadRequest(request)
        return await withCheckedContinuation { continuation in
            service.readSMARTDataWithCompletion(for: requestData) { data, error in
                continuation.resume(returning: (data, error))
            }
        }
    }

    private func cancelReply(
        from service: DrivePulseSMARTService,
        requestData: Data
    ) async -> (data: Data?, error: NSError?) {
        await withCheckedContinuation { continuation in
            service.cancelSMARTDataRequest(for: requestData) { data, error in
                continuation.resume(returning: (data, error))
            }
        }
    }

    private func handshakeReply(
        from service: DrivePulseSMARTService
    ) async -> (data: Data?, error: NSError?) {
        await withCheckedContinuation { continuation in
            service.fetchHelperHandshake { data, error in
                continuation.resume(returning: (data, error))
            }
        }
    }


    private func completionResponse(
        _ reply: (data: Data?, error: NSError?)
    ) throws -> SMARTReadCompletionResponse {
        XCTAssertNil(reply.error)
        return try DrivePulseXPCMessages.decodeSMARTReadCompletionResponse(
            from: XCTUnwrap(reply.data)
        )
    }

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

    func testBoundedFDEnumeratorRejectsInt32MaxAndNonStrideReports() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let huge = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, _, _ in Int32.max }
        )
        let unaligned = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            query: { _, _, _ in Int32(stride - 1) }
        )

        XCTAssertTrue(huge.descriptors.isEmpty)
        XCTAssertFalse(huge.isComplete)
        XCTAssertTrue(unaligned.descriptors.isEmpty)
        XCTAssertFalse(unaligned.isComplete)
    }

    func testBoundedFDEnumeratorCapsAlignedNearInt32MaxReportAndPreservesPrefix() {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let alignedHugeBytes = Int32.max - Int32(Int32.max % Int32(stride))
        var descriptor = proc_fdinfo(proc_fd: 12, proc_fdtype: 5)
        let payload = withUnsafeBytes(of: &descriptor) { Data($0) }
        let result = BoundedProcessFDEnumerator.enumerate(
            pid: 7,
            limits: ProcessInspectionLimits(maxFileDescriptorsPerProcess: 2),
            query: { _, buffer, byteCount in
                guard let buffer else { return alignedHugeBytes }
                guard byteCount == Int32(stride * 2) else { return -1 }
                payload.withUnsafeBytes { raw in
                    guard let source = raw.baseAddress else { return }
                    buffer.copyMemory(from: source, byteCount: payload.count)
                }
                return Int32(stride)
            }
        )

        XCTAssertEqual(result.descriptors, [ProcessFileDescriptor(number: 12, type: 5)])
        XCTAssertFalse(result.isComplete)
    }

    func testProcessInspectionLimitsCannotExceedFixedMemoryBudget() {
        XCTAssertEqual(
            ProcessInspectionLimits(maxFileDescriptorsPerProcess: .max).maxFileDescriptorsPerProcess,
            16_384
        )
    }

    func testBoundedFDEnumeratorMarksGrowthAfterSizingIncompleteWithoutOverreading() {
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

    func testSameWorkflowDifferentDiskIsBusyWithoutCancellingActiveWorker() async throws {
        let snapshot = ControlledSnapshotProvider()
        let endpoint = HelperOccupancyEndpoint(
            snapshotProvider: HelperAuthoritativeSnapshotProvider(snapshot: snapshot.scope),
            scanner: HelperOccupancyScanner(
                inspector: FixtureHelperProcessInspector(candidateCount: 0, holderPerPID: false)
            )
        )
        let workflowID = UUID()
        let firstRequest = try occupancyRequest(workflowID, disk: "disk4")
        let first = Task { await endpoint.handle(firstRequest) }
        await snapshot.waitUntilFirstStarted()

        let otherDisk = await endpoint.handle(try occupancyRequest(workflowID, disk: "disk5"))

        let callCount = await snapshot.callCountValue()
        let maximumWorkers = await snapshot.maximumActiveWorkers()
        XCTAssertEqual(otherDisk.error?.code, HelperOccupancyError.helperBusy.rawValue)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(maximumWorkers, 1)
        await snapshot.releaseFirst()
        let firstResult = await first.value
        XCTAssertTrue(
            try DrivePulseXPCMessages.decodeOccupancyResponse(
                from: XCTUnwrap(firstResult.data)
            ).isComplete
        )
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

private func companionInstallReply(
    from service: DrivePulseSMARTService,
    requestData: Data
) async -> (data: Data?, error: NSError?) {
    await withCheckedContinuation { continuation in
        service.installSmartctlCompanion(for: requestData) { data, error in
            continuation.resume(returning: (data, error))
        }
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

private struct SmartctlExecutableFixture: Sendable {
    let directory: URL
    let executable: URL
    let pidFile: URL
}

private struct FixtureSMARTDataRunner: SMARTDataRunning {
    let result: Result<Data, SmartctlRunner.RunnerError>
    let companionAvailable: Bool

    init(
        result: Result<Data, SmartctlRunner.RunnerError>,
        companionAvailable: Bool = true
    ) {
        self.result = result
        self.companionAvailable = companionAvailable
    }

    func readSMARTData(
        for physicalDeviceBSDName: String,
        transportHint: SmartctlTransportHint,
        timeout: Duration
    ) async throws -> Data {
        try result.get()
    }

    func isCompanionAvailable() -> Bool { companionAvailable }
}

private final class FixtureCompanionInstaller: SMARTCompanionInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var installedBinary: Data?

    var binary: Data? { lock.withLock { installedBinary } }

    func install(binary: Data) throws {
        lock.withLock { installedBinary = binary }
    }
}

private struct FixtureCompanionValidator: SMARTCompanionCodeValidating, Sendable {
    let error: SMARTCompanionInstallerError?

    init(error: SMARTCompanionInstallerError? = nil) {
        self.error = error
    }

    func validateCompanion(at url: URL) throws {
        if let error { throw error }
    }
}

private final class BlockingCompanionInstaller: SMARTCompanionInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var started = false
    private var count = 0

    var installCount: Int { lock.withLock { count } }

    func install(binary: Data) throws {
        let shouldBlock = lock.withLock {
            count += 1
            if count == 1 {
                started = true
                return true
            }
            return false
        }
        if shouldBlock { semaphore.wait() }
    }

    func waitUntilStarted() async {
        while lock.withLock({ started == false }) { await Task.yield() }
    }

    func release() {
        semaphore.signal()
    }
}

private actor BlockingSMARTDataRunner: SMARTDataRunning {
    private var started = 0
    private var released = false
    private var observedCancellation = false

    func readSMARTData(
        for physicalDeviceBSDName: String,
        transportHint: SmartctlTransportHint,
        timeout: Duration
    ) async throws -> Data {
        started += 1
        do {
            while released == false {
                try Task.checkCancellation()
                await Task.yield()
            }
        } catch {
            observedCancellation = true
            throw error
        }
        return Data(#"{"smart_status":{"passed":true}}"#.utf8)
    }

    nonisolated func isCompanionAvailable() -> Bool { true }

    func waitUntilStarted(count: Int) async {
        while started < count { await Task.yield() }
    }

    func releaseAll() { released = true }
    func startedCount() -> Int { started }
    func cancellationWasObserved() -> Bool { observedCancellation }
}

private final class SMARTReplyProbe: @unchecked Sendable {
    typealias Value = (data: Data?, error: NSError?)

    private let lock = NSLock()
    private var result: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    func start(service: DrivePulseSMARTService, request: SMARTReadRequest) {
        let requestData = try! DrivePulseXPCMessages.encodeSMARTReadRequest(request)
        service.readSMARTDataWithCompletion(for: requestData) { [self] data, error in
            finish((data, error))
        }
    }

    func startLegacy(service: DrivePulseSMARTService, request: SMARTReadRequest) {
        let requestData = try! DrivePulseXPCMessages.encodeSMARTReadRequest(request)
        service.readSMARTData(for: requestData) { [self] data, error in
            finish((data, error))
        }
    }

    func value() async -> Value {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Value? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    private func finish(_ value: Value) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Value, Never>] in
            guard result == nil else { return [] }
            result = value
            defer { waiters.removeAll() }
            return waiters
        }
        continuations.forEach { $0.resume(returning: value) }
    }
}
