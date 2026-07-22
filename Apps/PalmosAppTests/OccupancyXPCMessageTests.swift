import XCTest

@testable import PalmosApp

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

        let data = try PalmosXPCMessages.encodeOccupancyRequest(request)
        XCTAssertLessThanOrEqual(data.count, OccupancyXPCLimits.requestBytes)
        XCTAssertEqual(try PalmosXPCMessages.decodeOccupancyRequest(from: data), request)

        let oversized = OccupancyScanRequest(
            workflowID: request.workflowID,
            physicalDeviceBSDName: String(repeating: "d", count: OccupancyXPCLimits.requestBytes)
        )
        XCTAssertThrowsError(try PalmosXPCMessages.encodeOccupancyRequest(oversized)) { error in
            XCTAssertEqual(error as? PalmosXPCMessageError, .encodedMessageTooLarge)
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

        let data = try PalmosXPCMessages.encodeOccupancyResponse(.init(
            workflowID: workflowID,
            holders: holders,
            isComplete: true
        ))
        let decoded = try PalmosXPCMessages.decodeOccupancyResponse(from: data)

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

        let data = try PalmosXPCMessages.encodeOccupancyResponse(response)
        let holder = try XCTUnwrap(PalmosXPCMessages.decodeOccupancyResponse(from: data).holders.first)

        XCTAssertLessThanOrEqual(holder.executableName.utf8.count, OccupancyXPCLimits.maxNameUTF8Bytes)
        XCTAssertLessThanOrEqual(try XCTUnwrap(holder.displayName).utf8.count, OccupancyXPCLimits.maxNameUTF8Bytes)
        XCTAssertTrue(holder.executableName.allSatisfy { $0 == Character(family) })
        XCTAssertTrue(try XCTUnwrap(holder.displayName).allSatisfy { $0 == "界" })
    }

    func testSingleOversizedGraphemeFallsBackToValidUnicodeScalarBoundary() throws {
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 150)
        XCTAssertEqual(oversizedGrapheme.count, 1)
        XCTAssertGreaterThan(oversizedGrapheme.utf8.count, OccupancyXPCLimits.maxNameUTF8Bytes)

        let data = try PalmosXPCMessages.encodeOccupancyResponse(.init(
            workflowID: UUID(),
            holders: [.init(
                pid: 42,
                executableName: oversizedGrapheme,
                displayName: nil,
                type: "unknown"
            )],
            isComplete: true
        ))
        let name = try XCTUnwrap(
            PalmosXPCMessages.decodeOccupancyResponse(from: data).holders.first?.executableName
        )

        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.utf8.count, OccupancyXPCLimits.maxNameUTF8Bytes)
        XCTAssertNotNil(String(data: Data(name.utf8), encoding: .utf8))
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

        XCTAssertThrowsError(try PalmosXPCMessages.encodeOccupancyResponse(response)) { error in
            XCTAssertEqual(error as? PalmosXPCMessageError, .encodedMessageTooLarge)
        }
    }

    func testDecodeRejectsOversizedDataBeforeDecoding() {
        XCTAssertThrowsError(
            try PalmosXPCMessages.decodeOccupancyRequest(
                from: Data(repeating: 0x20, count: OccupancyXPCLimits.requestBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? PalmosXPCMessageError, .encodedMessageTooLarge)
        }
        XCTAssertThrowsError(
            try PalmosXPCMessages.decodeOccupancyResponse(
                from: Data(repeating: 0x20, count: OccupancyXPCLimits.responseBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? PalmosXPCMessageError, .encodedMessageTooLarge)
        }
    }

    func testDecodeRejectsExcessHoldersAndInvalidNames() throws {
        let excessiveHolders = OccupancyScanResponse(
            workflowID: UUID(),
            holders: (0...OccupancyXPCLimits.maxHolders).map { index in
                .init(pid: Int32(index), executableName: "process", displayName: nil, type: "unknown")
            },
            isComplete: true
        )
        XCTAssertThrowsError(
            try PalmosXPCMessages.decodeOccupancyResponse(
                from: PalmosXPCMessages.encode(excessiveHolders)
            )
        ) { error in
            XCTAssertEqual(error as? PalmosXPCMessageError, .invalidOccupancyMessage)
        }

        for holder in [
            OccupancyHolderMessage(pid: 1, executableName: "", displayName: nil, type: "unknown"),
            OccupancyHolderMessage(pid: 1, executableName: "process", displayName: "", type: "unknown"),
            OccupancyHolderMessage(
                pid: 1,
                executableName: String(repeating: "x", count: OccupancyXPCLimits.maxNameUTF8Bytes + 1),
                displayName: nil,
                type: "unknown"
            ),
            OccupancyHolderMessage(
                pid: 1,
                executableName: "process",
                displayName: String(repeating: "x", count: OccupancyXPCLimits.maxNameUTF8Bytes + 1),
                type: "unknown"
            )
        ] {
            let response = OccupancyScanResponse(workflowID: UUID(), holders: [holder], isComplete: true)
            XCTAssertThrowsError(
                try PalmosXPCMessages.decodeOccupancyResponse(
                    from: PalmosXPCMessages.encode(response)
                )
            ) { error in
                XCTAssertEqual(error as? PalmosXPCMessageError, .invalidOccupancyMessage)
            }
        }
    }

    func testDedupeWinnerAndEncodingAreIndependentOfInputOrder() throws {
        let workflowID = UUID()
        let candidates = [
            OccupancyHolderMessage(pid: 9, executableName: "zeta", displayName: nil, type: "deviceNode"),
            OccupancyHolderMessage(pid: 9, executableName: "beta", displayName: "Zeta", type: "deviceNode"),
            OccupancyHolderMessage(pid: 9, executableName: "alpha", displayName: "Alpha", type: "deviceNode")
        ]
        let forward = OccupancyScanResponse(workflowID: workflowID, holders: candidates, isComplete: true)
        let reverse = OccupancyScanResponse(
            workflowID: workflowID,
            holders: Array(candidates.reversed()),
            isComplete: true
        )

        let forwardData = try PalmosXPCMessages.encodeOccupancyResponse(forward)
        let reverseData = try PalmosXPCMessages.encodeOccupancyResponse(reverse)

        XCTAssertEqual(forwardData, reverseData)
        XCTAssertEqual(
            try PalmosXPCMessages.decodeOccupancyResponse(from: forwardData).holders.first?.displayName,
            "Alpha"
        )
    }

    func testEncodeRejectsPathologicalHolderCountsAndNamesBeforeNormalization() {
        let excessive = OccupancyScanResponse(
            workflowID: UUID(),
            holders: (0...OccupancyXPCLimits.maxInputHolders).map { index in
                .init(pid: Int32(index), executableName: "p", displayName: nil, type: "unknown")
            },
            isComplete: true
        )
        XCTAssertThrowsError(try PalmosXPCMessages.encodeOccupancyResponse(excessive)) { error in
            XCTAssertEqual(error as? PalmosXPCMessageError, .invalidOccupancyMessage)
        }

        let pathologicalName = String(repeating: "a", count: OccupancyXPCLimits.maxRawNameUTF8Bytes + 1)
        let response = OccupancyScanResponse(
            workflowID: UUID(),
            holders: [.init(pid: 1, executableName: pathologicalName, displayName: nil, type: "unknown")],
            isComplete: true
        )
        XCTAssertThrowsError(try PalmosXPCMessages.encodeOccupancyResponse(response)) { error in
            XCTAssertEqual(error as? PalmosXPCMessageError, .invalidOccupancyMessage)
        }
    }

    func testProtocolSelectorsRemainAdditiveAndLegacyPayloadBytesRemainUnchanged() {
        XCTAssertEqual(
            NSStringFromSelector(#selector(PalmosSMARTXPCProtocol.readSMARTData(for:withReply:))),
            "readSMARTDataFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(PalmosSMARTXPCProtocol.readSMARTDataWithCompletion(for:withReply:))),
            "readSMARTDataWithCompletionFor:withReply:"
        )
        XCTAssertEqual(
            NSStringFromSelector(#selector(PalmosSMARTXPCProtocol.scanDiskOccupancy(for:withReply:))),
            "scanDiskOccupancyFor:withReply:"
        )

        let rawJSON = Data(#"{"device":{"name":"/dev/disk4"},"bytes":[0,255]}"#.utf8)
        XCTAssertEqual(PalmosXPCMessages.legacySMARTReply(payload: rawJSON), rawJSON)
    }
}
