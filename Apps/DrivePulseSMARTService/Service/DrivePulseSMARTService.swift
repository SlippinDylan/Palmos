import DrivePulseCore
import Foundation

final class DrivePulseSMARTService: NSObject, DrivePulseSMARTXPCProtocol {
    private let runner: SmartctlRunner

    init(runner: SmartctlRunner = SmartctlRunner()) {
        self.runner = runner
    }

    func fetchHelperHandshake(withReply reply: @escaping (Data?, NSError?) -> Void) {
        do {
            reply(try HelperVersionHandshake.encodedCurrent(), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func readSMARTData(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let request = try DrivePulseXPCMessages.decode(
                SMARTReadRequest.self,
                from: requestData
            )
            let transportHint = TransportHintResolver.resolve(
                protocolName: request.deviceProtocol,
                modelName: request.deviceModel
            )
            let payload = try runner.readSMARTData(
                for: request.physicalDeviceBSDName,
                transportHint: transportHint
            )

            reply(payload, nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func readSMARTDataWithCompletion(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            let request = try DrivePulseXPCMessages.decode(
                SMARTReadRequest.self,
                from: requestData
            )
            let transportHint = TransportHintResolver.resolve(
                protocolName: request.deviceProtocol,
                modelName: request.deviceModel
            )
            let payload = try runner.readSMARTData(
                for: request.physicalDeviceBSDName,
                transportHint: transportHint
            )
            let response = SMARTReadCompletionResponse(
                schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
                payload: payload,
                processDidExit: true
            )
            reply(try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(response), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}
