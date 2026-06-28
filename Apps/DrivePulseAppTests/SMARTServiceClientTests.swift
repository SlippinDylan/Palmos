import XCTest
@testable import DrivePulseApp

final class SMARTServiceClientTests: XCTestCase {
    func testCompatibilityFromEncodedHandshakeUsesSerializedContractFields() throws {
        let client = SMARTServiceClient()
        let payload = HelperHandshake(
            helperVersion: "9.9.9",
            contractMajor: 1,
            contractMinor: 1
        )
        let encodedPayload = try DrivePulseXPCMessages.encode(payload)

        let result = try client.evaluateHandshake(from: encodedPayload)

        XCTAssertEqual(result, .degraded)
    }

    func testEncodeReadRequestRoundTripsThroughSharedMessageCodec() throws {
        let client = SMARTServiceClient()
        let request = SMARTReadRequest(
            physicalDeviceBSDName: "disk42",
            deviceProtocol: "USB",
            deviceModel: "Field SSD"
        )

        let encodedRequest = try client.encodeReadRequest(request)
        let decodedRequest = try DrivePulseXPCMessages.decode(
            SMARTReadRequest.self,
            from: encodedRequest
        )

        XCTAssertEqual(decodedRequest, request)
    }
}
