import XCTest

@testable import DrivePulseApp

final class OccupancyXPCMessageTests: XCTestCase {
    func testLimitsMatchTheBoundedProtocol() {
        XCTAssertEqual(OccupancyXPCLimits.requestBytes, 4 * 1024)
        XCTAssertEqual(OccupancyXPCLimits.responseBytes, 64 * 1024)
        XCTAssertEqual(OccupancyXPCLimits.maxHolders, 64)
        XCTAssertEqual(OccupancyXPCLimits.maxCandidatePIDs, 4_096)
        XCTAssertEqual(OccupancyXPCLimits.maxNameUTF8Bytes, 255)
    }

    func testRequestRoundTripsWithinLimitAndRejectsFinalDataAboveLimit() throws {
        let request = OccupancyScanRequest(
            workflowID: UUID(uuidString: "1778D52F-C453-4B2A-A0B2-9910B9714F13")!,
            physicalDeviceBSDName: "disk4"
        )

        let data = try DrivePulseXPCMessages.encodeOccupancyRequest(request)
        XCTAssertLessThanOrEqual(data.count, OccupancyXPCLimits.requestBytes)
        XCTAssertEqual(try DrivePulseXPCMessages.decodeOccupancyRequest(from: data), request)

        let oversized = OccupancyScanRequest(
            workflowID: request.workflowID,
            physicalDeviceBSDName: String(repeating: "d", count: OccupancyXPCLimits.requestBytes)
        )
        XCTAssertThrowsError(try DrivePulseXPCMessages.encodeOccupancyRequest(oversized)) { error in
            XCTAssertEqual(error as? DrivePulseXPCMessageError, .encodedMessageTooLarge)
        }
    }

    func testResponseDeduplicatesCapsAndRoundTrips() throws {
        let workflowID = UUID()
        let duplicate = OccupancyHolderMessage(
            pid: 7,
            executableName: "A shell",
            displayName: nil,
            type: "workingDirectory"
        )
        let holders = [duplicate, duplicate] + (0..<80).map { index in
            OccupancyHolderMessage(
                pid: Int32(index + 100),
                executableName: "process-\(index)",
                displayName: "Process \(index)",
                type: "openFileOrDirectory"
            )
        }

        let data = try DrivePulseXPCMessages.encodeOccupancyResponse(.init(
            workflowID: workflowID,
            holders: holders,
            isComplete: true
        ))
        let decoded = try DrivePulseXPCMessages.decodeOccupancyResponse(from: data)

        XCTAssertEqual(decoded.workflowID, workflowID)
        XCTAssertEqual(decoded.holders.count, OccupancyXPCLimits.maxHolders)
        XCTAssertEqual(decoded.holders.filter { $0.pid == 7 && $0.type == "workingDirectory" }.count, 1)
        XCTAssertLessThanOrEqual(data.count, OccupancyXPCLimits.responseBytes)
    }

    func testResponseTruncatesNamesAtCompleteCharacterBoundary() throws {
        let family = "👨‍👩‍👧‍👦"
        let response = OccupancyScanResponse(
            workflowID: UUID(),
            holders: [.init(
                pid: 42,
                executableName: String(repeating: family, count: 20),
                displayName: String(repeating: "界", count: 100),
                type: "deviceNode"
            )],
            isComplete: false
        )

        let data = try DrivePulseXPCMessages.encodeOccupancyResponse(response)
        let holder = try XCTUnwrap(DrivePulseXPCMessages.decodeOccupancyResponse(from: data).holders.first)

        XCTAssertLessThanOrEqual(holder.executableName.utf8.count, OccupancyXPCLimits.maxNameUTF8Bytes)
        XCTAssertLessThanOrEqual(try XCTUnwrap(holder.displayName).utf8.count, OccupancyXPCLimits.maxNameUTF8Bytes)
        XCTAssertTrue(holder.executableName.allSatisfy { $0 == Character(family) })
        XCTAssertTrue(try XCTUnwrap(holder.displayName).allSatisfy { $0 == "界" })
    }

    func testResponseRejectsFinalEncodedDataAboveLimitAfterNormalization() {
        let response = OccupancyScanResponse(
            workflowID: UUID(),
            holders: [.init(
                pid: 1,
                executableName: "process",
                displayName: nil,
                type: String(repeating: "x", count: OccupancyXPCLimits.responseBytes)
            )],
            isComplete: true
        )

        XCTAssertThrowsError(try DrivePulseXPCMessages.encodeOccupancyResponse(response)) { error in
            XCTAssertEqual(error as? DrivePulseXPCMessageError, .encodedMessageTooLarge)
        }
    }

    func testProtocolSelectorsRemainAdditiveAndLegacyPayloadBytesRemainUnchanged() {
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.readSMARTData(for:withReply:))),
            "readSMARTDataFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.readSMARTDataWithCompletion(for:withReply:))),
            "readSMARTDataWithCompletionFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(DrivePulseSMARTXPCProtocol.scanDiskOccupancy(for:withReply:))),
            "scanDiskOccupancyFor:withReply:"
        )

        let rawJSON = Data(#"{"device":{"name":"/dev/disk4"},"bytes":[0,255]}"#.utf8)
        XCTAssertEqual(DrivePulseXPCMessages.legacySMARTReply(payload: rawJSON), rawJSON)
    }
}
