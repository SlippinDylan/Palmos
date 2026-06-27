import Foundation

import DrivePulseCore

final class SMARTServiceClient {
    func evaluateHandshake(_ handshake: HelperHandshake) -> XPCCompatibilityResult {
        XPCCompatibilityPolicy.evaluate(
            appMajor: XPCContractVersion.currentMajor,
            appMinor: XPCContractVersion.currentMinor,
            helperMajor: handshake.contractMajor,
            helperMinor: handshake.contractMinor
        )
    }

    func decodeHandshake(from data: Data) throws -> HelperHandshake {
        try DrivePulseXPCMessages.decode(HelperHandshake.self, from: data)
    }

    func encodeReadRequest(_ request: SMARTReadRequest) throws -> Data {
        try DrivePulseXPCMessages.encode(request)
    }
}
