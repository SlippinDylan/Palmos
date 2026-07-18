import DrivePulseCore
import Foundation

final class DrivePulseSMARTService: NSObject, DrivePulseSMARTXPCProtocol, @unchecked Sendable {
    private let runner: any SMARTDataRunning
    private let occupancyEndpoint: HelperOccupancyEndpoint
    private let smartTaskRegistry: SMARTTaskRegistry
    private let companionInstaller: any SMARTCompanionInstalling
    private let companionInstallationGate = SMARTCompanionInstallationGate()

    init(
        runner: any SMARTDataRunning = SmartctlRunner(),
        occupancyEndpoint: HelperOccupancyEndpoint = HelperOccupancyEndpoint(),
        companionInstaller: any SMARTCompanionInstalling = SmartctlCompanionInstaller(),
        maxConcurrentSMARTRequests: Int = 4,
        maxConcurrentSMARTRequestsPerDevice: Int = 1
    ) {
        self.runner = runner
        self.occupancyEndpoint = occupancyEndpoint
        self.companionInstaller = companionInstaller
        self.smartTaskRegistry = SMARTTaskRegistry(
            maxConcurrentRequests: maxConcurrentSMARTRequests,
            maxConcurrentRequestsPerDevice: maxConcurrentSMARTRequestsPerDevice
        )
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
            let data = try HelperVersionHandshake.encodedCurrent(
                smartctlCompanionAvailable: runner.isCompanionAvailable()
            )
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
        let runner = runner
        let registry = smartTaskRegistry
        let request: SMARTReadRequest
        do {
            request = try DrivePulseXPCMessages.decodeSMARTReadRequest(from: requestData)
        } catch {
            replyBox.call(nil, error as NSError)
            return
        }

        let admission = registry.reserve(
            requestID: request.requestID,
            physicalDeviceBSDName: request.physicalDeviceBSDName
        )
        if admission.rejection == .duplicateRequest {
            replyBox.call(nil, SMARTServiceError.duplicateRequest as NSError)
            return
        }
        if admission.rejection == .busy {
            replyBox.call(nil, SMARTServiceError.busy as NSError)
            return
        }
        guard let reservation = admission.reservation else {
            replyBox.call(nil, SMARTServiceError.busy as NSError)
            return
        }
        SMARTReadOperation(
            runner: runner,
            registry: registry,
            reservationToken: reservation.token,
            request: request,
            replyBox: replyBox,
            mode: .legacy
        ).start(using: reservation.handle)
    }

    func readSMARTDataWithCompletion(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        let runner = runner
        let registry = smartTaskRegistry
        let request: SMARTReadRequest
        do {
            request = try DrivePulseXPCMessages.decodeSMARTReadRequest(from: requestData)
        } catch {
            replyCompletion(
                requestID: nil,
                deviceSMARTIOQuiesced: false,
                error: .init(code: .invalidRequest, message: error.localizedDescription),
                using: replyBox
            )
            return
        }

        let admission = registry.reserve(
            requestID: request.requestID,
            physicalDeviceBSDName: request.physicalDeviceBSDName
        )
        if admission.rejection == .duplicateRequest {
            replyCompletion(
                requestID: request.requestID,
                deviceSMARTIOQuiesced: false,
                error: .init(
                    code: .duplicateRequest,
                    message: "A SMART request with this identifier is already active."
                ),
                using: replyBox
            )
            return
        }
        if admission.rejection == .busy {
            replyCompletion(
                requestID: request.requestID,
                deviceSMARTIOQuiesced: false,
                error: .init(
                    code: .busy,
                    message: "The SMART helper is at its bounded concurrency limit."
                ),
                using: replyBox
            )
            return
        }
        guard let reservation = admission.reservation else {
            replyCompletion(
                requestID: request.requestID,
                deviceSMARTIOQuiesced: false,
                error: .init(code: .busy, message: "The SMART helper cannot admit this request."),
                using: replyBox
            )
            return
        }
        SMARTReadOperation(
            runner: runner,
            registry: registry,
            reservationToken: reservation.token,
            request: request,
            replyBox: replyBox,
            mode: .completionAware
        ).start(using: reservation.handle)
    }

    /// Legacy minor-5 cancellation selector retained for compatibility.
    func cancelSMARTData(for requestID: String) {
        guard requestID.utf8.count <= SMARTXPCLimits.legacyCancelRequestUTF8Bytes,
              let requestID = UUID(uuidString: requestID)?.uuidString.lowercased() else { return }
        _ = smartTaskRegistry.cancel(requestID: requestID)
    }

    func cancelSMARTDataRequest(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        do {
            let request = try DrivePulseXPCMessages.decodeSMARTCancelRequest(from: requestData)
            let result: SMARTCancelResult = smartTaskRegistry.cancel(requestID: request.requestID)
                ? .accepted
                : .notFound
            let acknowledgement = SMARTCancelAcknowledgement(
                schemaVersion: SMARTCancelAcknowledgement.currentSchemaVersion,
                requestID: request.requestID,
                result: result
            )
            replyBox.call(
                try DrivePulseXPCMessages.encodeSMARTCancelAcknowledgement(acknowledgement),
                nil
            )
        } catch {
            replyBox.call(nil, error as NSError)
        }
    }

    func installSmartctlCompanion(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    ) {
        let replyBox = XPCReplyBox(reply)
        guard companionInstallationGate.begin() else {
            replyBox.call(nil, SMARTServiceError.busy as NSError)
            return
        }
        let companionInstaller = companionInstaller
        let companionInstallationGate = companionInstallationGate
        Task.detached(priority: .userInitiated) {
            let result: (Data?, NSError?)
            do {
                let request = try DrivePulseXPCMessages.decodeSMARTCompanionInstallRequest(
                    from: requestData
                )
                try companionInstaller.install(binary: request.binary)
                let acknowledgement = SMARTCompanionInstallAcknowledgement(
                    schemaVersion: SMARTCompanionInstallAcknowledgement.currentSchemaVersion,
                    result: .installed
                )
                result = (
                    try DrivePulseXPCMessages.encodeSMARTCompanionInstallAcknowledgement(
                        acknowledgement
                    ),
                    nil
                )
            } catch {
                result = (nil, error as NSError)
            }
            companionInstallationGate.finish()
            replyBox.call(result.0, result.1)
        }
    }

    private func replyCompletion(
        requestID: String?,
        deviceSMARTIOQuiesced: Bool,
        error: SMARTReadCompletionError,
        using replyBox: XPCReplyBox
    ) {
        Self.replyCompletion(
            requestID: requestID,
            deviceSMARTIOQuiesced: deviceSMARTIOQuiesced,
            error: error,
            using: replyBox
        )
    }

    fileprivate static func replyCompletion(
        requestID: String?,
        deviceSMARTIOQuiesced: Bool,
        error: SMARTReadCompletionError,
        using replyBox: XPCReplyBox
    ) {
        do {
            let response = SMARTReadCompletionResponse(
                schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
                payload: Data(),
                processDidExit: true,
                deviceSMARTIOQuiesced: deviceSMARTIOQuiesced,
                requestID: requestID,
                error: error
            )
            replyBox.call(
                try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(response),
                nil
            )
        } catch {
            replyBox.call(nil, error as NSError)
        }
    }

}

private final class SMARTReadOperation: @unchecked Sendable {
    enum Mode: Sendable {
        case legacy
        case completionAware
    }

    private let runner: any SMARTDataRunning
    private let registry: SMARTTaskRegistry
    private let reservationToken: UUID
    private let request: SMARTReadRequest
    private let replyBox: XPCReplyBox
    private let mode: Mode

    init(
        runner: any SMARTDataRunning,
        registry: SMARTTaskRegistry,
        reservationToken: UUID,
        request: SMARTReadRequest,
        replyBox: XPCReplyBox,
        mode: Mode
    ) {
        self.runner = runner
        self.registry = registry
        self.reservationToken = reservationToken
        self.request = request
        self.replyBox = replyBox
        self.mode = mode
    }

    func start(using handle: SMARTTaskHandle) {
        let task = Task { await run() }
        handle.attach(task)
    }

    private func run() async {
        defer { registry.remove(token: reservationToken) }
        do {
            let transportHint = TransportHintResolver.resolve(
                protocolName: request.deviceProtocol,
                modelName: request.deviceModel
            )
            let payload = try await runner.readSMARTData(
                for: request.physicalDeviceBSDName,
                transportHint: transportHint,
                timeout: SmartctlRunner.defaultTimeout
            )
            try DrivePulseXPCMessages.validateSMARTPayload(payload)
            switch mode {
            case .legacy:
                replyBox.call(DrivePulseXPCMessages.legacySMARTReply(payload: payload), nil)
            case .completionAware:
                let response = SMARTReadCompletionResponse(
                    schemaVersion: SMARTReadCompletionResponse.currentSchemaVersion,
                    payload: payload,
                    processDidExit: true,
                    deviceSMARTIOQuiesced: true,
                    requestID: request.requestID,
                    error: nil
                )
                replyBox.call(
                    try DrivePulseXPCMessages.encodeSMARTReadCompletionResponse(response),
                    nil
                )
            }
        } catch {
            switch mode {
            case .legacy:
                replyBox.call(nil, error as NSError)
            case .completionAware:
                DrivePulseSMARTService.replyCompletion(
                    requestID: request.requestID,
                    deviceSMARTIOQuiesced: true,
                    error: smartCompletionError(for: error),
                    using: replyBox
                )
            }
        }
    }
}

private func smartCompletionError(for error: Error) -> SMARTReadCompletionError {
    if error is CancellationError {
        return .init(code: .cancelled, message: "The SMART request was cancelled after process termination.")
    }
    guard let runnerError = error as? SmartctlRunner.RunnerError else {
        return .init(code: .internalFailure, message: error.localizedDescription)
    }
    let code: SMARTReadCompletionErrorCode
    switch runnerError {
    case .invalidDeviceName:
        code = .invalidRequest
    case .executableUnavailable:
        code = .executableUnavailable
    case .timedOut:
        code = .timedOut
    case .commandFailed, .emptyOutput:
        code = .commandFailed
    case .outputTooLarge:
        code = .outputTooLarge
    }
    return .init(code: code, message: runnerError.localizedDescription)
}

private final class SMARTCompanionInstallationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isInstalling = false

    func begin() -> Bool {
        lock.withLock {
            guard isInstalling == false else { return false }
            isInstalling = true
            return true
        }
    }

    func finish() {
        lock.withLock { isInstalling = false }
    }
}

private enum SMARTServiceError: LocalizedError {
    case duplicateRequest
    case busy

    var errorDescription: String? {
        switch self {
        case .duplicateRequest:
            return "A SMART request with this identifier is already active."
        case .busy:
            return "The SMART helper is at its bounded concurrency limit."
        }
    }
}

private final class SMARTTaskRegistry: @unchecked Sendable {
    struct Reservation: @unchecked Sendable {
        let token: UUID
        let requestID: String?
        let physicalDeviceBSDName: String
        let handle: SMARTTaskHandle
    }

    enum Rejection: Equatable {
        case duplicateRequest
        case busy
    }

    struct Admission {
        let reservation: Reservation?
        let rejection: Rejection?

        static func accepted(_ reservation: Reservation) -> Self {
            Self(reservation: reservation, rejection: nil)
        }

        static func rejected(_ rejection: Rejection) -> Self {
            Self(reservation: nil, rejection: rejection)
        }
    }

    private let maxConcurrentRequests: Int
    private let maxConcurrentRequestsPerDevice: Int
    private let lock = NSLock()
    private var reservations: [UUID: Reservation] = [:]
    private var tokensByRequestID: [String: UUID] = [:]
    private var activeCountsByDevice: [String: Int] = [:]

    init(maxConcurrentRequests: Int, maxConcurrentRequestsPerDevice: Int) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.maxConcurrentRequestsPerDevice = max(1, maxConcurrentRequestsPerDevice)
    }

    func reserve(requestID: String?, physicalDeviceBSDName: String) -> Admission {
        lock.withLock {
            let requestID = requestID?.lowercased()
            if let requestID, tokensByRequestID[requestID] != nil {
                return .rejected(.duplicateRequest)
            }
            guard reservations.count < maxConcurrentRequests,
                  activeCountsByDevice[physicalDeviceBSDName, default: 0] < maxConcurrentRequestsPerDevice else {
                return .rejected(.busy)
            }

            let reservation = Reservation(
                token: UUID(),
                requestID: requestID,
                physicalDeviceBSDName: physicalDeviceBSDName,
                handle: SMARTTaskHandle()
            )
            reservations[reservation.token] = reservation
            if let requestID { tokensByRequestID[requestID] = reservation.token }
            activeCountsByDevice[physicalDeviceBSDName, default: 0] += 1
            return .accepted(reservation)
        }
    }

    func remove(token: UUID) {
        let removed = lock.withLock { () -> Reservation? in
            guard let current = reservations[token] else { return nil }
            reservations.removeValue(forKey: token)
            if let requestID = current.requestID { tokensByRequestID.removeValue(forKey: requestID) }
            if activeCountsByDevice[current.physicalDeviceBSDName] == 1 {
                activeCountsByDevice.removeValue(forKey: current.physicalDeviceBSDName)
            } else if let count = activeCountsByDevice[current.physicalDeviceBSDName] {
                activeCountsByDevice[current.physicalDeviceBSDName] = count - 1
            }
            return current
        }
        removed?.handle.detach()
    }

    func cancel(requestID: String) -> Bool {
        let handle = lock.withLock { () -> SMARTTaskHandle? in
            guard let token = tokensByRequestID[requestID],
                  let reservation = reservations[token] else { return nil }
            return reservation.handle
        }
        handle?.cancel()
        return handle != nil
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

fileprivate final class XPCReplyBox: @unchecked Sendable {
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
