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

    init(
        helperMachServiceName: String = "com.drivepulse.smartservice",
        isHelperInstalled: (@Sendable () -> Bool)? = nil,
        fetchHelperHandshake: (@Sendable () async throws -> Data)? = nil,
        readSMARTData: (@Sendable (Data) async throws -> Data)? = nil
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
            let compatibility = try evaluateHandshake(from: handshakeData)

            guard compatibility != .updateRequired else {
                return .updateRequired
            }

            let request = SMARTReadRequest(
                physicalDeviceBSDName: device.physicalStoreBSDName,
                deviceProtocol: device.transportName,
                deviceModel: device.displayName
            )
            let requestData = try encodeReadRequest(request)
            let payload = try await readSMARTDataOperation(requestData)
            let smartData = try SmartDataParser.parse(jsonData: payload)
            return .available(smartData, compatibility: compatibility)
        } catch {
            return mapRefreshError(error)
        }
    }

    private static func fetchHelperHandshake(helperMachServiceName: String) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, continuation in
            proxy.fetchHelperHandshake { data, error in
                connection.invalidate()
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(throwing: SMARTServiceClientError.missingReplyData)
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    private static func readSMARTData(
        _ requestData: Data,
        helperMachServiceName: String
    ) async throws -> Data {
        try await withConnection(helperMachServiceName: helperMachServiceName) { proxy, connection, continuation in
            proxy.readSMARTData(for: requestData) { data, error in
                connection.invalidate()
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data else {
                    continuation.resume(throwing: SMARTServiceClientError.missingReplyData)
                    return
                }

                continuation.resume(returning: data)
            }
        }
    }

    private static func withConnection(
        helperMachServiceName: String,
        _ operation: @escaping (
            DrivePulseSMARTXPCProtocol,
            NSXPCConnection,
            CheckedContinuation<Data, Error>
        ) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: helperMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: DrivePulseSMARTXPCProtocol.self)
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate()
                continuation.resume(throwing: error)
            }

            guard let proxy = proxy as? DrivePulseSMARTXPCProtocol else {
                connection.invalidate()
                continuation.resume(throwing: SMARTServiceClientError.invalidRemoteProxy)
                return
            }

            operation(proxy, connection, continuation)
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

    var errorDescription: String? {
        switch self {
        case .invalidRemoteProxy:
            return "Failed to create the SMART helper XPC proxy."
        case .missingReplyData:
            return "The SMART helper returned an empty response."
        }
    }
}
