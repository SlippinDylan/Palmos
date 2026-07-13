import DrivePulseCore
import Foundation

final class DrivePulseSMARTService: NSObject, DrivePulseSMARTXPCProtocol {
    private let runner: SmartctlRunner
    private let occupancyEndpoint: HelperOccupancyEndpoint

    init(
        runner: SmartctlRunner = SmartctlRunner(),
        occupancyEndpoint: HelperOccupancyEndpoint = HelperOccupancyEndpoint()
    ) {
        self.runner = runner
        self.occupancyEndpoint = occupancyEndpoint
    }

    func scanDiskOccupancy(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let endpoint = occupancyEndpoint
        Task {
            let result = await endpoint.handle(requestData)
            replyBox.call(result.data, result.error)
        }
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

            reply(DrivePulseXPCMessages.legacySMARTReply(payload: payload), nil)
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

private final class XPCReplyBox: @unchecked Sendable {
    private let reply: (Data?, NSError?) -> Void
    init(_ reply: @escaping (Data?, NSError?) -> Void) { self.reply = reply }
    func call(_ data: Data?, _ error: NSError?) { reply(data, error) }
}
