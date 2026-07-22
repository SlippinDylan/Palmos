import Foundation

import DrivePulseCore

enum SMARTServiceRefreshResult: Equatable, Sendable {
    case available(SmartData, compatibility: XPCCompatibilityResult)
    case unsupported
    case transportUnsupported
    case companionUnavailable
    case helperNotInstalled
    case updateRequired
    case permissionRequired
    case deviceUnavailable
    case failed(String)
}

protocol SMARTServiceProviding: Sendable {
    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult
    func refreshSMART(
        for device: ExternalDevice,
        topologyGeneration: Int
    ) async -> SMARTServiceRefreshResult
}

protocol SMARTCompanionProvisioning: Sendable {
    func installBundledSmartctlCompanion(_ binary: Data) async throws
}

extension SMARTServiceProviding {
    func refreshSMART(
        for device: ExternalDevice,
        topologyGeneration: Int
    ) async -> SMARTServiceRefreshResult {
        await refreshSMART(for: device)
    }
}

final class SMARTServiceClient: SMARTServiceProviding, SMARTHelperInspecting,
    HelperOccupancyScanning, SMARTCompanionProvisioning
{
    private let handshakeClient: SMARTHandshakeClient
    private let readSMARTDataOperation: @Sendable (Data) async throws -> Data
    private let readSMARTDataWithCompletionOperation: (@Sendable (Data) async throws -> Data)?
    private let installSmartctlCompanionOperation: @Sendable (Data) async throws -> Data
    private let completionSessionFactory: (@Sendable () -> any SMARTCompletionXPCSession)?
    private let occupancyClient: OccupancyXPCClient
    private let errorMapper: SMARTServiceErrorMapper
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
        installSmartctlCompanion: (@Sendable (Data) async throws -> Data)? = nil,
        scanDiskOccupancy: (@Sendable (Data) async throws -> Data)? = nil,
        occupancySessionFactory: (@Sendable () -> any OccupancyXPCSession)? = nil,
        completionSessionFactory: (@Sendable () -> any SMARTCompletionXPCSession)? = nil,
        completionSession: (any SMARTCompletionXPCSession)? = nil,
        deviceIOTracker: DeviceIOTracker? = nil
    ) {
        let isHelperInstalledOperation = isHelperInstalled ?? {
            Self.isHelperInstalled(label: helperMachServiceName)
        }
        let fetchHelperHandshakeOperation = fetchHelperHandshake ?? {
            try await SMARTXPCConnectionFactory.fetchHelperHandshake(
                helperMachServiceName: helperMachServiceName
            )
        }
        let handshakeClient = SMARTHandshakeClient(
            isHelperInstalled: isHelperInstalledOperation,
            fetchHandshake: fetchHelperHandshakeOperation
        )

        self.handshakeClient = handshakeClient
        self.readSMARTDataOperation = readSMARTData ?? { requestData in
            try await SMARTXPCConnectionFactory.readSMARTData(
                requestData,
                helperMachServiceName: helperMachServiceName
            )
        }
        if let completionSessionFactory {
            self.completionSessionFactory = completionSessionFactory
        } else if let completionSession {
            self.completionSessionFactory = { completionSession }
        } else if readSMARTData == nil && readSMARTDataWithCompletion == nil {
            self.completionSessionFactory = {
                LiveSMARTCompletionXPCSession(helperMachServiceName: helperMachServiceName)
            }
        } else {
            self.completionSessionFactory = nil
        }
        self.readSMARTDataWithCompletionOperation = readSMARTDataWithCompletion
        self.installSmartctlCompanionOperation = installSmartctlCompanion ?? { requestData in
            try await SMARTXPCConnectionFactory.installSmartctlCompanion(
                requestData,
                helperMachServiceName: helperMachServiceName
            )
        }
        let resolvedOccupancySessionFactory = scanDiskOccupancy == nil
            ? occupancySessionFactory ?? {
                LiveOccupancyXPCSession(helperMachServiceName: helperMachServiceName)
            }
            : nil
        self.occupancyClient = OccupancyXPCClient(
            handshakeClient: handshakeClient,
            scanDiskOccupancy: scanDiskOccupancy,
            sessionFactory: resolvedOccupancySessionFactory
        )
        self.errorMapper = SMARTServiceErrorMapper(
            isHelperInstalled: isHelperInstalledOperation
        )
        self.deviceIOTracker = deviceIOTracker
    }

    func evaluateHandshake(_ handshake: HelperHandshake) -> XPCCompatibilityResult {
        handshakeClient.evaluate(handshake)
    }

    func evaluateHandshake(from data: Data) throws -> XPCCompatibilityResult {
        try handshakeClient.evaluate(from: data)
    }

    func inspectSMARTHelper() async -> SMARTHelperInspection {
        await handshakeClient.inspect()
    }

    func decodeHandshake(from data: Data) throws -> HelperHandshake {
        try handshakeClient.decode(from: data)
    }

    func encodeReadRequest(_ request: SMARTReadRequest) throws -> Data {
        try DrivePulseXPCMessages.encodeSMARTReadRequest(request)
    }

    func installBundledSmartctlCompanion(_ binary: Data) async throws {
        let requestData = try DrivePulseXPCMessages.encodeSMARTCompanionInstallRequest(.init(
            binary: binary
        ))
        let acknowledgementData = try await installSmartctlCompanionOperation(requestData)
        let acknowledgement = try DrivePulseXPCMessages.decodeSMARTCompanionInstallAcknowledgement(
            from: acknowledgementData
        )
        guard acknowledgement.result == .installed else {
            throw SMARTServiceClientError.companionInstallationUnconfirmed
        }

        let handshake = try await handshakeClient.fetch()
        let capabilities = handshakeClient.capabilities(for: handshake)
        guard handshakeClient.evaluate(handshake) != .updateRequired,
              capabilities.smartctlCompanionInstallation,
              handshake.smartctlCompanionAvailable == true else {
            throw SMARTServiceClientError.companionInstallationUnconfirmed
        }
    }

    func refreshSMART(for device: ExternalDevice) async -> SMARTServiceRefreshResult {
        await refreshSMART(for: device, topologyGeneration: 0)
    }

    func refreshSMART(
        for device: ExternalDevice,
        topologyGeneration: Int
    ) async -> SMARTServiceRefreshResult {
        var token: DeviceIOTracker.Token?
        do {
            let handshake = try await handshakeClient.fetch()
            let compatibility = handshakeClient.evaluate(handshake)

            guard compatibility != .updateRequired else {
                return .updateRequired
            }
            let capabilities = handshakeClient.capabilities(for: handshake)
            guard capabilities.observableSMARTFailures else {
                return .updateRequired
            }
            let request = SMARTReadRequest(
                physicalDeviceBSDName: device.physicalStoreBSDName,
                deviceProtocol: device.transportName,
                deviceModel: device.displayName,
                requestID: capabilities.smartCancellation ? UUID().uuidString : nil
            )
            let requestData = try encodeReadRequest(request)
            token = try await deviceIOTracker?.beginTargetOperation(
                deviceID: device.id,
                physicalBSDName: device.physicalStoreBSDName,
                topologyGeneration: topologyGeneration,
                kind: .smart
            )
            let payload: Data
            if capabilities.completionAwareSMART,
               completionSessionFactory != nil || readSMARTDataWithCompletionOperation != nil {
                let responseData: Data
                if let completionSession = completionSessionFactory?() {
                    responseData = try await SMARTReadXPCSession.readSMARTData(
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
                guard response.requestID == request.requestID else {
                    throw SMARTServiceClientError.mismatchedSMARTRequest
                }
                payload = response.payload
                if let token {
                    await deviceIOTracker?.finishSMARTCompletion(
                        token,
                        clearsPriorSafetyScopes: response.deviceSMARTIOQuiesced == true
                    )
                }
                token = nil
                if let completionError = response.error {
                    return errorMapper.mapCompletionError(completionError)
                }
            } else {
                payload = try await readSMARTDataOperation(requestData)
                try DrivePulseXPCMessages.validateSMARTPayload(payload)
                if let token {
                    await deviceIOTracker?.finishSMARTCompletion(
                        token,
                        clearsPriorSafetyScopes: false
                    )
                }
                token = nil
            }
            let smartData = try SmartDataParser.parse(jsonData: payload)
            return .available(smartData, compatibility: compatibility)
        } catch {
            if let token {
                await deviceIOTracker?.markSMARTCompletionUnobservable(token)
            }
            return errorMapper.mapRefreshError(error)
        }
    }

    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult {
        try await occupancyClient.scan(
            workflowID: workflowID,
            physicalBSDName: physicalBSDName
        )
    }

    private static func isHelperInstalled(label: String) -> Bool {
        let fileManager = FileManager.default
        let helperToolPath = "/Library/PrivilegedHelperTools/\(label)"
        let launchDaemonPath = "/Library/LaunchDaemons/\(label).plist"
        return fileManager.fileExists(atPath: helperToolPath) &&
            fileManager.fileExists(atPath: launchDaemonPath)
    }
}
