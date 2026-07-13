import DrivePulseCore
import Foundation

final class DrivePulseSMARTService: NSObject, DrivePulseSMARTXPCProtocol {
    private let runner: SmartctlRunner
    private let occupancyValidator: HelperOccupancyRequestValidator
    private let topologyResolver: HelperDiskTopologyResolver
    private let occupancyScanner: HelperOccupancyScanner

    init(
        runner: SmartctlRunner = SmartctlRunner(),
        occupancyValidator: HelperOccupancyRequestValidator = HelperOccupancyRequestValidator(),
        topologyResolver: HelperDiskTopologyResolver = HelperDiskTopologyResolver(),
        occupancyScanner: HelperOccupancyScanner = HelperOccupancyScanner()
    ) {
        self.runner = runner
        self.occupancyValidator = occupancyValidator
        self.topologyResolver = topologyResolver
        self.occupancyScanner = occupancyScanner
    }

    func scanDiskOccupancy(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        do {
            try HelperOccupancyRequestValidator.validateRequestBytes(requestData)
            let request = try DrivePulseXPCMessages.decodeOccupancyRequest(from: requestData)
            let replyBox = XPCReplyBox(reply)
            let validator = occupancyValidator
            let resolver = topologyResolver
            let scanner = occupancyScanner
            Task {
                do {
                    try await validator.validate(request)
                    let scope = try await resolver.resolve(
                        wholeBSDName: request.physicalDeviceBSDName
                    )
                    let response = try await scanner.scan(
                        workflowID: request.workflowID,
                        scope: scope
                    )
                    replyBox.call(try DrivePulseXPCMessages.encodeOccupancyResponse(response), nil)
                } catch let error as HelperOccupancyError {
                    replyBox.call(nil, error.nsError)
                } catch {
                    replyBox.call(nil, HelperOccupancyError.scanFailed.nsError)
                }
            }
        } catch let error as HelperOccupancyError {
            reply(nil, error.nsError)
        } catch {
            reply(nil, HelperOccupancyError.invalidRequest.nsError)
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
