import DrivePulseCore
import Foundation

final class DrivePulseSMARTService: NSObject, DrivePulseSMARTXPCProtocol {
    private let runner: SmartctlRunner
    private let occupancyEndpoint: HelperOccupancyEndpoint
    private let smartTaskRegistry = SMARTTaskRegistry()

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
            let data = try HelperVersionHandshake.encodedCurrent()
            guard data.count <= SMARTXPCLimits.handshakeBytes else {
                throw DrivePulseXPCMessageError.encodedMessageTooLarge
            }
            reply(data, nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func readSMARTData(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let runner = self.runner
        let registry = smartTaskRegistry
        let requestID = decodedRequestID(from: requestData)
        let taskHandle = requestID.map { registry.reserve(requestID: $0) }
        let task = Task { [registry] in
            do {
                let request = try DrivePulseXPCMessages.decodeSMARTReadRequest(from: requestData)
                let transportHint = TransportHintResolver.resolve(
                    protocolName: request.deviceProtocol,
                    modelName: request.deviceModel
                )
                let payload = try await runner.readSMARTData(
                    for: request.physicalDeviceBSDName,
                    transportHint: transportHint
                )
                try DrivePulseXPCMessages.validateSMARTPayload(payload)
                replyBox.call(DrivePulseXPCMessages.legacySMARTReply(payload: payload), nil)
            } catch {
                replyBox.call(nil, error as NSError)
            }
            registry.remove(requestID: requestID, handle: taskHandle)
        }
        taskHandle?.attach(task)
    }

    func readSMARTDataWithCompletion(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let runner = self.runner
        let registry = smartTaskRegistry
        let requestID = decodedRequestID(from: requestData)
        let taskHandle = requestID.map { registry.reserve(requestID: $0) }
        let task = Task { [registry] in
            do {
                let request = try DrivePulseXPCMessages.decodeSMARTReadRequest(from: requestData)
                let transportHint = TransportHintResolver.resolve(
                    protocolName: request.deviceProtocol,
                    modelName: request.deviceModel
                )
                let payload = try await runner.readSMARTData(
                    for: request.physicalDeviceBSDName,
                    transportHint: transportHint
                )
                let response = SMARTReadCompletionResponse(
                    schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
                    payload: payload,
                    processDidExit: true
                )
                replyBox.call(try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(response), nil)
            } catch {
                replyBox.call(nil, error as NSError)
            }
            registry.remove(requestID: requestID, handle: taskHandle)
        }
        taskHandle?.attach(task)
    }

    func cancelSMARTData(for requestID: String) {
        smartTaskRegistry.cancel(requestID: requestID)
    }

    private func decodedRequestID(from requestData: Data) -> String? {
        guard let request = try? DrivePulseXPCMessages.decodeSMARTReadRequest(from: requestData),
              let requestID = request.requestID,
              UUID(uuidString: requestID) != nil else { return nil }
        return requestID
    }
}

private final class SMARTTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: SMARTTaskHandle] = [:]

    func reserve(requestID: String) -> SMARTTaskHandle {
        let handle = SMARTTaskHandle()
        lock.withLock { tasks[requestID] = handle }
        return handle
    }

    func remove(requestID: String?, handle: SMARTTaskHandle?) {
        guard let requestID, let handle else { return }
        lock.withLock {
            guard tasks[requestID] === handle else { return }
            tasks.removeValue(forKey: requestID)
        }
        handle.detach()
    }

    func cancel(requestID: String) {
        let handle = lock.withLock { tasks[requestID] }
        handle?.cancel()
    }
}

private final class SMARTTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func attach(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            self.task = task
            return isCancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func detach() {
        lock.withLock { task = nil }
    }
}

private final class XPCReplyBox: @unchecked Sendable {
    private let reply: (Data?, NSError?) -> Void
    private let lock = NSLock()
    private var didReply = false
    init(_ reply: @escaping (Data?, NSError?) -> Void) { self.reply = reply }
    func call(_ data: Data?, _ error: NSError?) {
        let shouldReply = lock.withLock {
            guard didReply == false else { return false }
            didReply = true
            return true
        }
        guard shouldReply else { return }
        reply(data, error)
    }
}
