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

final class SMARTServiceClient: SMARTServiceProviding {
    private let helperMachServiceName: String
    private let isHelperInstalledOperation: @Sendable () -> Bool
    private let fetchHelperHandshakeOperation: @Sendable () async throws -> Data
    private let readSMARTDataOperation: @Sendable (Data) async throws -> Data
    private let readSMARTDataWithCompletionOperation: (@Sendable (Data) async throws -> Data)?
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
        if let readSMARTDataWithCompletion {
            self.readSMARTDataWithCompletionOperation = readSMARTDataWithCompletion
        } else if readSMARTData == nil {
            self.readSMARTDataWithCompletionOperation = { requestData in
                try await Self.readSMARTDataWithCompletion(
                    requestData,
                    helperMachServiceName: helperMachServiceName
                )
            }
        } else {
            self.readSMARTDataWithCompletionOperation = nil
        }
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

    func decodeHandshake(from data: Data) throws -> HelperHandshake {
        try DrivePulseXPCMessages.decode(HelperHandshake.self, from: data)
    }

    func encodeReadRequest(_ request: SMARTReadRequest) throws -> Data {
        try DrivePulseXPCMessages.encode(request)
    }

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
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
            let token = try await deviceIOTracker?.beginTargetOperation(
                physicalBSDName: device.physicalStoreBSDName,
                kind: .smart
            )
            let payload: Data
            if XPCFeatureCapabilities.negotiated(
                helperContractMinor: handshake.contractMinor
            ).completionAwareSMART,
               let readSMARTDataWithCompletionOperation {
                let responseData = try await readSMARTDataWithCompletionOperation(requestData)
                let response = try DrivePulseXPCMessages.decodeAcknowledgedSMARTReadCompletionResponse(
                    from: responseData
                )
                payload = response.payload
                if let token { await deviceIOTracker?.finish(token) }
            } else {
                payload = try await readSMARTDataOperation(requestData)
                if let token { await deviceIOTracker?.finish(token) }
            }
            let smartData = try SmartDataParser.parse(jsonData: payload)
            return .available(smartData, compatibility: compatibility)
        } catch {
            return mapRefreshError(error)
        }
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

    private static func readSMARTDataWithCompletion(
        _ requestData: Data,
        helperMachServiceName: String
    ) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, gate in
            proxy.readSMARTDataWithCompletion(for: requestData) { data, error in
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

private enum SMARTServiceClientError: LocalizedError {
    case invalidRemoteProxy
    case missingReplyData
    case connectionInterrupted
    case connectionInvalidated

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
