import Foundation

enum SMARTXPCSessionEvent: @unchecked Sendable {
    case reply(Data)
    case failure(Error)
    case interrupted
    case invalidated
}

protocol SMARTCompletionXPCSession: Sendable {
    func readSMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    )

    func querySMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    )

    func invalidate()
}

extension SMARTCompletionXPCSession {
    func invalidate() {}

    func querySMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        eventHandler(.failure(SMARTServiceClientError.unsupportedSectionedSMARTEndpoint))
    }
}

enum SMARTReadXPCSession {
    static func readSMARTData(
        _ requestData: Data,
        using session: any SMARTCompletionXPCSession,
        requestTimeout: Duration = .seconds(25)
    ) async throws -> Data {
        try await perform(using: session, requestTimeout: requestTimeout) { eventHandler in
            session.readSMARTData(requestData: requestData, eventHandler: eventHandler)
        }
    }

    static func querySMARTData(
        _ requestData: Data,
        using session: any SMARTCompletionXPCSession,
        requestTimeout: Duration = .seconds(25)
    ) async throws -> Data {
        try await perform(using: session, requestTimeout: requestTimeout) { eventHandler in
            session.querySMARTData(requestData: requestData, eventHandler: eventHandler)
        }
    }

    private static func perform(
        using session: any SMARTCompletionXPCSession,
        requestTimeout: Duration,
        operation: @escaping (@escaping @Sendable (SMARTXPCSessionEvent) -> Void) -> Void
    ) async throws -> Data {
        let cancellation = SMARTCompletionCancellation(session: session)
        let deadline = ContinuousClock.now.advanced(by: requestTimeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = XPCReplyGate(continuation: continuation)
                guard cancellation.start(gate: gate, operation: {
                    operation { event in
                        switch event {
                        case let .reply(data):
                            gate.resume(returning: data)
                        case let .failure(error):
                            gate.resume(throwing: error)
                        case .interrupted:
                            gate.resume(throwing: SMARTServiceClientError.connectionInterrupted)
                        case .invalidated:
                            gate.resume(throwing: SMARTServiceClientError.connectionInvalidated)
                        }
                    }
                }) else {
                    gate.resume(throwing: CancellationError())
                    return
                }
                Task {
                    try? await ContinuousClock().sleep(until: deadline)
                    cancellation.timeout(gate: gate)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

final class LiveSMARTCompletionXPCSession: SMARTCompletionXPCSession, @unchecked Sendable {
    private let helperMachServiceName: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var requestID: String?

    init(helperMachServiceName: String) {
        self.helperMachServiceName = helperMachServiceName
    }

    func readSMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        let requestID = (try? PalmosXPCMessages.decodeSMARTReadRequest(from: requestData))?.requestID
        let connection = NSXPCConnection(
            machServiceName: helperMachServiceName,
            options: .privileged
        )
        lock.withLock {
            self.connection = connection
            self.requestID = requestID
        }
        connection.interruptionHandler = { eventHandler(.interrupted) }
        connection.invalidationHandler = { eventHandler(.invalidated) }
        connection.remoteObjectInterface = NSXPCInterface(with: PalmosSMARTXPCProtocol.self)
        connection.activate()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            eventHandler(.failure(error))
            self.finish(connection)
        }
        guard let proxy = proxy as? PalmosSMARTXPCProtocol else {
            eventHandler(.failure(SMARTServiceClientError.invalidRemoteProxy))
            connection.invalidate()
            return
        }
        proxy.readSMARTDataWithCompletion(for: requestData) { data, error in
            if let error {
                eventHandler(.failure(error))
            } else if let data {
                eventHandler(.reply(data))
            } else {
                eventHandler(.failure(SMARTServiceClientError.missingReplyData))
            }
            self.finish(connection)
        }
    }

    func querySMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        let requestID = (try? PalmosXPCMessages.decodeSMARTQueryRequest(from: requestData))?.requestID
        performRequest(requestID: requestID, eventHandler: eventHandler) { proxy, reply in
            guard proxy.querySMARTData != nil else {
                eventHandler(.failure(SMARTServiceClientError.unsupportedSectionedSMARTEndpoint))
                return false
            }
            proxy.querySMARTData?(for: requestData, withReply: reply)
            return true
        }
    }

    func invalidate() {
        let (connection, requestID) = lock.withLock {
            (self.connection, self.requestID)
        }
        guard let connection else { return }
        guard let requestID,
              let proxy = connection.remoteObjectProxy as? PalmosSMARTXPCProtocol else {
            finish(connection)
            return
        }
        do {
            let requestData = try PalmosXPCMessages.encodeSMARTCancelRequest(.init(
                requestID: requestID
            ))
            guard proxy.cancelSMARTDataRequest != nil else {
                proxy.cancelSMARTData?(for: requestID)
                return
            }
            proxy.cancelSMARTDataRequest?(for: requestData) { data, error in
                guard error == nil, let data else { return }
                _ = try? PalmosXPCMessages.decodeSMARTCancelAcknowledgement(from: data)
            }
        } catch {
            finish(connection)
        }
    }

    private func finish(_ connection: NSXPCConnection) {
        lock.withLock {
            if self.connection === connection {
                self.connection = nil
                self.requestID = nil
            }
        }
        connection.invalidate()
    }

    private func performRequest(
        requestID: String?,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void,
        start: (PalmosSMARTXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Bool
    ) {
        let connection = NSXPCConnection(
            machServiceName: helperMachServiceName,
            options: .privileged
        )
        lock.withLock {
            self.connection = connection
            self.requestID = requestID
        }
        connection.interruptionHandler = { eventHandler(.interrupted) }
        connection.invalidationHandler = { eventHandler(.invalidated) }
        connection.remoteObjectInterface = NSXPCInterface(with: PalmosSMARTXPCProtocol.self)
        connection.activate()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            eventHandler(.failure(error))
            self.finish(connection)
        }
        guard let proxy = proxy as? PalmosSMARTXPCProtocol else {
            eventHandler(.failure(SMARTServiceClientError.invalidRemoteProxy))
            connection.invalidate()
            return
        }
        let didStart = start(proxy) { data, error in
            if let error {
                eventHandler(.failure(error))
            } else if let data {
                eventHandler(.reply(data))
            } else {
                eventHandler(.failure(SMARTServiceClientError.missingReplyData))
            }
            self.finish(connection)
        }
        if didStart == false {
            finish(connection)
        }
    }
}

private final class SMARTCompletionCancellation: @unchecked Sendable {
    private let session: any SMARTCompletionXPCSession
    private let lock = NSLock()
    private var gate: XPCReplyGate?
    private var isCancelled = false

    init(session: any SMARTCompletionXPCSession) {
        self.session = session
    }

    func start(gate: XPCReplyGate, operation: () -> Void) -> Bool {
        lock.withLock {
            guard isCancelled == false else { return false }
            self.gate = gate
            operation()
            return true
        }
    }

    func cancel() {
        let shouldInvalidate = lock.withLock { () -> Bool in
            guard isCancelled == false else { return false }
            isCancelled = true
            return true
        }
        // Keep awaiting the Helper's completion envelope: cancellation alone is not
        // evidence that smartctl exited, and eject must remain fail-closed until it is.
        if shouldInvalidate { session.invalidate() }
    }

    func timeout(gate: XPCReplyGate) {
        guard gate.resume(throwing: SMARTServiceClientError.smartRequestTimedOut) else {
            return
        }
        session.invalidate()
    }
}
