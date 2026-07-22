import Foundation

protocol OccupancyXPCSession: Sendable {
    func fetchHelperHandshake(
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    )
    func scanDiskOccupancy(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    )
    func invalidate()
}

struct OccupancyXPCClient: Sendable {
    private let handshakeClient: SMARTHandshakeClient
    private let scanDiskOccupancy: (@Sendable (Data) async throws -> Data)?
    private let sessionFactory: (@Sendable () -> any OccupancyXPCSession)?

    init(
        handshakeClient: SMARTHandshakeClient,
        scanDiskOccupancy: (@Sendable (Data) async throws -> Data)?,
        sessionFactory: (@Sendable () -> any OccupancyXPCSession)?
    ) {
        self.handshakeClient = handshakeClient
        self.scanDiskOccupancy = scanDiskOccupancy
        self.sessionFactory = sessionFactory
    }

    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult {
        if let sessionFactory {
            return try await scan(
                workflowID: workflowID,
                physicalBSDName: physicalBSDName,
                using: sessionFactory()
            )
        }

        let handshake = try await handshakeClient.fetch()
        let capabilities = handshakeClient.capabilities(for: handshake)
        guard handshakeClient.evaluate(handshake) != .updateRequired,
              capabilities.occupancyScanning else {
            return OccupancyScanResult(holders: [], isComplete: false)
        }

        let requestData = try PalmosXPCMessages.encodeOccupancyRequest(.init(
            workflowID: workflowID,
            physicalDeviceBSDName: physicalBSDName
        ))
        try Task.checkCancellation()
        guard let scanDiskOccupancy else {
            throw SMARTServiceClientError.unsupportedOccupancyEndpoint
        }
        let responseData = try await scanDiskOccupancy(requestData)
        try Task.checkCancellation()
        return try occupancyResult(from: responseData, workflowID: workflowID)
    }

    private func scan(
        workflowID: UUID,
        physicalBSDName: String,
        using session: any OccupancyXPCSession
    ) async throws -> OccupancyScanResult {
        let cancellation = OccupancyXPCSessionCancellation(session: session)
        return try await withTaskCancellationHandler {
            do {
                let handshakeData = try await Self.receive(using: cancellation) { eventHandler in
                    session.fetchHelperHandshake(eventHandler: eventHandler)
                }
                try Task.checkCancellation()
                let handshake = try handshakeClient.decode(from: handshakeData)
                let capabilities = handshakeClient.capabilities(for: handshake)
                guard handshakeClient.evaluate(handshake) != .updateRequired,
                      capabilities.occupancyScanning else {
                    session.invalidate()
                    return OccupancyScanResult(holders: [], isComplete: false)
                }

                let requestData = try PalmosXPCMessages.encodeOccupancyRequest(.init(
                    workflowID: workflowID,
                    physicalDeviceBSDName: physicalBSDName
                ))
                try Task.checkCancellation()
                let responseData = try await Self.receive(using: cancellation) { eventHandler in
                    session.scanDiskOccupancy(requestData: requestData, eventHandler: eventHandler)
                }
                try Task.checkCancellation()
                return try occupancyResult(from: responseData, workflowID: workflowID)
            } catch {
                if Task.isCancelled == false { session.invalidate() }
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func occupancyResult(
        from responseData: Data,
        workflowID: UUID
    ) throws -> OccupancyScanResult {
        let response = try PalmosXPCMessages.decodeOccupancyResponse(from: responseData)
        guard response.workflowID == workflowID else {
            throw SMARTServiceClientError.mismatchedOccupancyWorkflow
        }
        return OccupancyScanResult(
            holders: response.holders.map { holder in
                OccupancyHolder(
                    pid: holder.pid,
                    executableName: holder.executableName,
                    displayName: holder.displayName,
                    type: OccupancyType(rawValue: holder.type) ?? .unknown
                )
            },
            isComplete: response.isComplete
        )
    }

    private static func receive(
        using cancellation: OccupancyXPCSessionCancellation,
        operation: (@escaping @Sendable (SMARTXPCSessionEvent) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate(continuation: continuation)
            let didStart = cancellation.start(gate: gate) {
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
            }
            if didStart == false { gate.resume(throwing: CancellationError()) }
        }
    }
}

final class LiveOccupancyXPCSession: OccupancyXPCSession, @unchecked Sendable {
    private let helperMachServiceName: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(helperMachServiceName: String) {
        self.helperMachServiceName = helperMachServiceName
    }

    func fetchHelperHandshake(
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        let connection = connection(for: eventHandler)
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            eventHandler(.failure(error))
            self?.finish(connection)
        }
        guard let proxy = proxy as? PalmosSMARTXPCProtocol else {
            eventHandler(.failure(SMARTServiceClientError.invalidRemoteProxy))
            finish(connection)
            return
        }
        proxy.fetchHelperHandshake { [weak self] data, error in
            if let error {
                eventHandler(.failure(error))
                self?.finish(connection)
            } else if let data {
                eventHandler(.reply(data))
            } else {
                eventHandler(.failure(SMARTServiceClientError.missingReplyData))
                self?.finish(connection)
            }
        }
    }

    func scanDiskOccupancy(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        let connection = connection(for: eventHandler)
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            eventHandler(.failure(error))
            self?.finish(connection)
        }
        guard let proxy = proxy as? PalmosSMARTXPCProtocol,
              proxy.scanDiskOccupancy != nil else {
            eventHandler(.failure(SMARTServiceClientError.unsupportedOccupancyEndpoint))
            invalidate()
            return
        }
        proxy.scanDiskOccupancy?(for: requestData) { [weak self] data, error in
            if let error {
                eventHandler(.failure(error))
            } else if let data {
                eventHandler(.reply(data))
            } else {
                eventHandler(.failure(SMARTServiceClientError.missingReplyData))
            }
            self?.finish(connection)
        }
    }

    func invalidate() {
        let connection = lock.withLock {
            defer { self.connection = nil }
            return self.connection
        }
        connection?.invalidate()
    }

    private func finish(_ connection: NSXPCConnection) {
        lock.withLock {
            if self.connection === connection { self.connection = nil }
        }
        connection.invalidate()
    }

    private func connection(
        for eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) -> NSXPCConnection {
        lock.withLock {
            if let connection {
                connection.interruptionHandler = { eventHandler(.interrupted) }
                connection.invalidationHandler = { eventHandler(.invalidated) }
                return connection
            }
            let connection = NSXPCConnection(
                machServiceName: helperMachServiceName,
                options: .privileged
            )
            connection.interruptionHandler = { eventHandler(.interrupted) }
            connection.invalidationHandler = { eventHandler(.invalidated) }
            connection.remoteObjectInterface = NSXPCInterface(with: PalmosSMARTXPCProtocol.self)
            connection.resume()
            self.connection = connection
            return connection
        }
    }
}

private final class OccupancyXPCSessionCancellation: @unchecked Sendable {
    private let session: any OccupancyXPCSession
    private let lock = NSLock()
    private var gate: XPCReplyGate?
    private var isCancelled = false

    init(session: any OccupancyXPCSession) {
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
        var shouldCancel = false
        let gate = lock.withLock { () -> XPCReplyGate? in
            guard isCancelled == false else { return nil }
            isCancelled = true
            shouldCancel = true
            return self.gate
        }
        guard shouldCancel else { return }
        gate?.resume(throwing: CancellationError())
        session.invalidate()
    }
}
