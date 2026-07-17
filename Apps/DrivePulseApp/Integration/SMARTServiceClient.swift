import Foundation

import DrivePulseCore

enum SMARTServiceRefreshResult: Equatable, Sendable {
    case available(SmartData, compatibility: XPCCompatibilityResult)
    case unsupported
    case transportUnsupported
    case helperNotInstalled
    case updateRequired
    case permissionRequired
    case deviceUnavailable
    case failed(String)
}

protocol SMARTServiceProviding: Sendable {
    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult
}

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
}

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

final class SMARTServiceClient: SMARTServiceProviding, SMARTHelperInspecting, HelperOccupancyScanning {
    private let helperMachServiceName: String
    private let isHelperInstalledOperation: @Sendable () -> Bool
    private let fetchHelperHandshakeOperation: @Sendable () async throws -> Data
    private let readSMARTDataOperation: @Sendable (Data) async throws -> Data
    private let readSMARTDataWithCompletionOperation: (@Sendable (Data) async throws -> Data)?
    private let scanDiskOccupancyOperation: (@Sendable (Data) async throws -> Data)?
    private let completionSession: (any SMARTCompletionXPCSession)?
    private let occupancySessionFactory: (@Sendable () -> any OccupancyXPCSession)?
    private let deviceIOTracker: DeviceIOTracker?

    func usesDeviceIOTracker(_ tracker: DeviceIOTracker) -> Bool {
        deviceIOTracker === tracker
    }

    init(
        helperMachServiceName: String = "com.drivepulse.smartservice",
        isHelperInstalled: (@Sendable () -> Bool)? = nil,
        fetchHelperHandshake: (@Sendable () async throws -> Data)? = nil,
        readSMARTData: (@Sendable (Data) async throws -> Data)? = nil,
        readSMARTDataWithCompletion: (@Sendable (Data) async throws -> Data)? = nil,
        scanDiskOccupancy: (@Sendable (Data) async throws -> Data)? = nil,
        occupancySessionFactory: (@Sendable () -> any OccupancyXPCSession)? = nil,
        completionSession: (any SMARTCompletionXPCSession)? = nil,
        deviceIOTracker: DeviceIOTracker? = nil
    ) {
        self.helperMachServiceName = helperMachServiceName
        self.isHelperInstalledOperation = isHelperInstalled ?? {
            Self.isHelperInstalled(label: helperMachServiceName)
        }
        self.fetchHelperHandshakeOperation = fetchHelperHandshake ?? {
            try await Self.fetchHelperHandshake(helperMachServiceName: helperMachServiceName)
        }
        self.readSMARTDataOperation = readSMARTData ?? { requestData in
            try await Self.readSMARTData(
                requestData,
                helperMachServiceName: helperMachServiceName
            )
        }
        self.completionSession = completionSession ?? (
            readSMARTData == nil && readSMARTDataWithCompletion == nil
                ? LiveSMARTCompletionXPCSession(helperMachServiceName: helperMachServiceName)
                : nil
        )
        if let readSMARTDataWithCompletion {
            self.readSMARTDataWithCompletionOperation = readSMARTDataWithCompletion
        } else {
            self.readSMARTDataWithCompletionOperation = nil
        }
        self.scanDiskOccupancyOperation = scanDiskOccupancy
        self.occupancySessionFactory = scanDiskOccupancy == nil
            ? occupancySessionFactory ?? {
                LiveOccupancyXPCSession(helperMachServiceName: helperMachServiceName)
            }
            : nil
        self.deviceIOTracker = deviceIOTracker
    }

    func evaluateHandshake(_ handshake: HelperHandshake) -> XPCCompatibilityResult {
        XPCCompatibilityPolicy.evaluate(
            appMajor: XPCContractVersion.currentMajor,
            appMinor: XPCContractVersion.currentMinor,
            helperMajor: handshake.contractMajor,
            helperMinor: handshake.contractMinor
        )
    }

    func evaluateHandshake(from data: Data) throws -> XPCCompatibilityResult {
        evaluateHandshake(try decodeHandshake(from: data))
    }

    func inspectSMARTHelper() async -> SMARTHelperInspection {
        guard isHelperInstalledOperation() else {
            return .notInstalled
        }

        do {
            let handshakeData = try await fetchHelperHandshakeOperation()
            let handshake = try decodeHandshake(from: handshakeData)
            return evaluateHandshake(handshake) == .updateRequired
                ? .updateRequired
                : .installed
        } catch {
            return isHelperInstalledOperation()
                ? .failed(error.localizedDescription)
                : .notInstalled
        }
    }

    func decodeHandshake(from data: Data) throws -> HelperHandshake {
        try DrivePulseXPCMessages.decode(HelperHandshake.self, from: data)
    }

    func encodeReadRequest(_ request: SMARTReadRequest) throws -> Data {
        try DrivePulseXPCMessages.encode(request)
    }

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        var token: DeviceIOTracker.Token?
        do {
            let handshakeData = try await fetchHelperHandshakeOperation()
            let handshake = try decodeHandshake(from: handshakeData)
            let compatibility = evaluateHandshake(handshake)

            guard compatibility != .updateRequired else {
                return .updateRequired
            }

            let request = SMARTReadRequest(
                physicalDeviceBSDName: device.physicalStoreBSDName,
                deviceProtocol: device.transportName,
                deviceModel: device.displayName
            )
            let requestData = try encodeReadRequest(request)
            token = try await deviceIOTracker?.beginTargetOperation(
                deviceID: device.id,
                physicalBSDName: device.physicalStoreBSDName,
                kind: .smart
            )
            let payload: Data
            if XPCFeatureCapabilities.negotiated(
                helperContractMinor: handshake.contractMinor
            ).completionAwareSMART,
               completionSession != nil || readSMARTDataWithCompletionOperation != nil {
                let responseData: Data
                if let completionSession {
                    responseData = try await Self.readSMARTData(
                        requestData,
                        using: completionSession
                    )
                } else if let readSMARTDataWithCompletionOperation {
                    responseData = try await readSMARTDataWithCompletionOperation(requestData)
                } else {
                    throw SMARTServiceClientError.missingReplyData
                }
                let response = try DrivePulseXPCMessages.decodeAcknowledgedSMARTReadCompletionResponse(
                    from: responseData
                )
                payload = response.payload
                if let token { await deviceIOTracker?.finish(token) }
                token = nil
            } else {
                payload = try await readSMARTDataOperation(requestData)
                if let token { await deviceIOTracker?.finish(token) }
                token = nil
            }
            let smartData = try SmartDataParser.parse(jsonData: payload)
            return .available(smartData, compatibility: compatibility)
        } catch {
            if let token {
                await deviceIOTracker?.markSMARTCompletionUnobservable(token)
            }
            return mapRefreshError(error)
        }
    }

    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult {
        if let occupancySessionFactory {
            return try await scan(
                workflowID: workflowID,
                physicalBSDName: physicalBSDName,
                using: occupancySessionFactory()
            )
        }

        let handshakeData = try await fetchHelperHandshakeOperation()
        try Task.checkCancellation()
        let handshake = try decodeHandshake(from: handshakeData)
        let capabilities = XPCFeatureCapabilities.negotiated(
            helperContractMinor: handshake.contractMinor
        )
        guard evaluateHandshake(handshake) != .updateRequired,
              capabilities.occupancyScanning else {
            return OccupancyScanResult(holders: [], isComplete: false)
        }

        let requestData = try DrivePulseXPCMessages.encodeOccupancyRequest(.init(
            workflowID: workflowID,
            physicalDeviceBSDName: physicalBSDName
        ))
        try Task.checkCancellation()
        guard let scanDiskOccupancyOperation else {
            throw SMARTServiceClientError.unsupportedOccupancyEndpoint
        }
        let responseData = try await scanDiskOccupancyOperation(requestData)
        try Task.checkCancellation()
        return try occupancyResult(from: responseData, workflowID: workflowID)
    }

    private func scan(
        workflowID: UUID,
        physicalBSDName: String,
        using session: any OccupancyXPCSession
    ) async throws -> OccupancyScanResult {
        let cancellation = XPCSessionCancellation(session: session)
        return try await withTaskCancellationHandler {
            do {
                let handshakeData = try await Self.receive(using: cancellation) { eventHandler in
                    session.fetchHelperHandshake(eventHandler: eventHandler)
                }
                try Task.checkCancellation()
                let handshake = try decodeHandshake(from: handshakeData)
                let capabilities = XPCFeatureCapabilities.negotiated(
                    helperContractMinor: handshake.contractMinor
                )
                guard evaluateHandshake(handshake) != .updateRequired,
                      capabilities.occupancyScanning else {
                    session.invalidate()
                    return OccupancyScanResult(holders: [], isComplete: false)
                }

                let requestData = try DrivePulseXPCMessages.encodeOccupancyRequest(.init(
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
        let response = try DrivePulseXPCMessages.decodeOccupancyResponse(from: responseData)
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

    private static func fetchHelperHandshake(helperMachServiceName: String) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, gate in
            proxy.fetchHelperHandshake { data, error in
                if let error {
                    gate.resume(throwing: error)
                    connection.invalidate()
                    return
                }

                guard let data else {
                    gate.resume(throwing: SMARTServiceClientError.missingReplyData)
                    connection.invalidate()
                    return
                }

                gate.resume(returning: data)
                connection.invalidate()
            }
        }
    }

    private static func readSMARTData(
        _ requestData: Data,
        helperMachServiceName: String
    ) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, gate in
            proxy.readSMARTData(for: requestData) { data, error in
                if let error {
                    gate.resume(throwing: error)
                    connection.invalidate()
                    return
                }

                guard let data else {
                    gate.resume(throwing: SMARTServiceClientError.missingReplyData)
                    connection.invalidate()
                    return
                }

                gate.resume(returning: data)
                connection.invalidate()
            }
        }
    }

    private static func receive(
        using cancellation: XPCSessionCancellation,
        operation: (@escaping @Sendable (SMARTXPCSessionEvent) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate(continuation: continuation)
            let didStart = cancellation.start(gate: gate) {
                operation { event in
                    switch event {
                    case let .reply(data): gate.resume(returning: data)
                    case let .failure(error): gate.resume(throwing: error)
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

    private static func readSMARTData(
        _ requestData: Data,
        using session: any SMARTCompletionXPCSession
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate(continuation: continuation)
            session.readSMARTData(requestData: requestData) { event in
                switch event {
                case let .reply(data): gate.resume(returning: data)
                case let .failure(error): gate.resume(throwing: error)
                case .interrupted: gate.resume(throwing: SMARTServiceClientError.connectionInterrupted)
                case .invalidated: gate.resume(throwing: SMARTServiceClientError.connectionInvalidated)
                }
            }
        }
    }

    private static func withConnection(
        helperMachServiceName: String,
        _ operation: @escaping (
            DrivePulseSMARTXPCProtocol,
            NSXPCConnection,
            XPCReplyGate
        ) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: helperMachServiceName,
                options: .privileged
            )
            let gate = XPCReplyGate(continuation: continuation)
            connection.interruptionHandler = {
                gate.resume(throwing: SMARTServiceClientError.connectionInterrupted)
            }
            connection.invalidationHandler = {
                gate.resume(throwing: SMARTServiceClientError.connectionInvalidated)
            }
            connection.remoteObjectInterface = NSXPCInterface(with: DrivePulseSMARTXPCProtocol.self)
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                gate.resume(throwing: error)
                connection.invalidate()
            }

            guard let proxy = proxy as? DrivePulseSMARTXPCProtocol else {
                gate.resume(throwing: SMARTServiceClientError.invalidRemoteProxy)
                connection.invalidate()
                return
            }

            operation(proxy, connection, gate)
        }
    }

    private func mapRefreshError(_ error: Error) -> SMARTServiceRefreshResult {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        let normalizedDescription = description.lowercased()

        if nsError.domain == NSCocoaErrorDomain && nsError.code == 4099 {
            return isHelperInstalledOperation() ? .failed(description) : .helperNotInstalled
        }

        if let connectionError = error as? SMARTServiceClientError,
           connectionError == .connectionInterrupted ||
           connectionError == .connectionInvalidated {
            return isHelperInstalledOperation() ? .failed(description) : .helperNotInstalled
        }

        if nsError.domain == NSPOSIXErrorDomain &&
            (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) {
            return .permissionRequired
        }

        if normalizedDescription.contains("unsupported smart device name") {
            return .deviceUnavailable
        }

        if normalizedDescription.contains("smart support is unavailable") ||
            normalizedDescription.contains("smart unavailable") {
            return .unsupported
        }

        if normalizedDescription.contains("using transport hint") &&
            (normalizedDescription.contains("unknown usb bridge") ||
                normalizedDescription.contains("unknown bridge") ||
                normalizedDescription.contains("specify device type")) {
            return .transportUnsupported
        }

        return .failed(description)
    }

    private static func isHelperInstalled(label: String) -> Bool {
        let fileManager = FileManager.default
        let helperToolPath = "/Library/PrivilegedHelperTools/\(label)"
        let launchDaemonPath = "/Library/LaunchDaemons/\(label).plist"
        return fileManager.fileExists(atPath: helperToolPath) &&
            fileManager.fileExists(atPath: launchDaemonPath)
    }
}

private final class LiveSMARTCompletionXPCSession: SMARTCompletionXPCSession, @unchecked Sendable {
    private let helperMachServiceName: String

    init(helperMachServiceName: String) {
        self.helperMachServiceName = helperMachServiceName
    }

    func readSMARTData(
        requestData: Data,
        eventHandler: @escaping @Sendable (SMARTXPCSessionEvent) -> Void
    ) {
        let connection = NSXPCConnection(
            machServiceName: helperMachServiceName,
            options: .privileged
        )
        connection.interruptionHandler = { eventHandler(.interrupted) }
        connection.invalidationHandler = { eventHandler(.invalidated) }
        connection.remoteObjectInterface = NSXPCInterface(with: DrivePulseSMARTXPCProtocol.self)
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            eventHandler(.failure(error))
            connection.invalidate()
        }
        guard let proxy = proxy as? DrivePulseSMARTXPCProtocol else {
            eventHandler(.failure(SMARTServiceClientError.invalidRemoteProxy))
            connection.invalidate()
            return
        }
        proxy.readSMARTDataWithCompletion(for: requestData) { data, error in
            if let error { eventHandler(.failure(error)) }
            else if let data { eventHandler(.reply(data)) }
            else { eventHandler(.failure(SMARTServiceClientError.missingReplyData)) }
            connection.invalidate()
        }
    }
}

private final class LiveOccupancyXPCSession: OccupancyXPCSession, @unchecked Sendable {
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
        guard let proxy = proxy as? DrivePulseSMARTXPCProtocol else {
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
        guard let proxy = proxy as? DrivePulseSMARTXPCProtocol,
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
            connection.remoteObjectInterface = NSXPCInterface(with: DrivePulseSMARTXPCProtocol.self)
            connection.resume()
            self.connection = connection
            return connection
        }
    }
}

enum SMARTServiceClientError: LocalizedError, Equatable {
    case invalidRemoteProxy
    case missingReplyData
    case connectionInterrupted
    case connectionInvalidated
    case unsupportedOccupancyEndpoint
    case mismatchedOccupancyWorkflow

    var errorDescription: String? {
        switch self {
        case .invalidRemoteProxy:
            return "Failed to create the SMART helper XPC proxy."
        case .missingReplyData:
            return "The SMART helper returned an empty response."
        case .connectionInterrupted:
            return "The SMART helper connection was interrupted."
        case .connectionInvalidated:
            return "The SMART helper connection was invalidated before completion."
        case .unsupportedOccupancyEndpoint:
            return "The SMART helper does not support disk occupancy scans."
        case .mismatchedOccupancyWorkflow:
            return "The SMART helper returned an occupancy result for another workflow."
        }
    }
}

final class XPCReplyGate: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Error>
    private let lock = NSLock()
    private var didResume = false

    init(continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(returning data: Data) {
        resume(.success(data))
    }

    func resume(throwing error: Error) {
        resume(.failure(error))
    }

    private func resume(_ result: Result<Data, Error>) {
        let shouldResume = lock.withLock {
            guard didResume == false else { return false }
            didResume = true
            return true
        }
        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}

private final class XPCSessionCancellation: @unchecked Sendable {
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
