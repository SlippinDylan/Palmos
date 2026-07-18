import Foundation

struct HelperHandshake: Codable, Equatable, Sendable {
    let helperVersion: String
    let contractMajor: Int
    let contractMinor: Int
    let smartctlCompanionAvailable: Bool?

    init(
        helperVersion: String,
        contractMajor: Int,
        contractMinor: Int,
        smartctlCompanionAvailable: Bool? = nil
    ) {
        self.helperVersion = helperVersion
        self.contractMajor = contractMajor
        self.contractMinor = contractMinor
        self.smartctlCompanionAvailable = smartctlCompanionAvailable
    }
}

struct SMARTReadRequest: Codable, Equatable, Sendable {
    let physicalDeviceBSDName: String
    let deviceProtocol: String?
    let deviceModel: String?
    let requestID: String?

    init(
        physicalDeviceBSDName: String,
        deviceProtocol: String?,
        deviceModel: String?,
        requestID: String? = nil
    ) {
        self.physicalDeviceBSDName = physicalDeviceBSDName
        self.deviceProtocol = deviceProtocol
        self.deviceModel = deviceModel
        self.requestID = requestID
    }
}

struct SMARTReadCompletionResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let payload: Data
    /// True means this request is process-quiesced: its child exited or no
    /// child was launched. It says nothing about another request that may have
    /// been rejected as a duplicate or due to backpressure.
    let processDidExit: Bool
    /// True means this admitted request reached its terminal runner state, so
    /// the client may clear prior unobservable SMART I/O for the same device.
    /// False means this request was rejected before admission and proves
    /// nothing about another request already using that device.
    let deviceSMARTIOQuiesced: Bool?
    let requestID: String?
    let error: SMARTReadCompletionError?

    init(
        schemaVersion: Int,
        payload: Data,
        processDidExit: Bool,
        deviceSMARTIOQuiesced: Bool? = nil,
        requestID: String? = nil,
        error: SMARTReadCompletionError? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.processDidExit = processDidExit
        self.deviceSMARTIOQuiesced = deviceSMARTIOQuiesced
        self.requestID = requestID
        self.error = error
    }
}

enum SMARTReadCompletionErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case executableUnavailable
    case timedOut
    case commandFailed
    case cancelled
    case busy
    case duplicateRequest
    case outputTooLarge
    case internalFailure
}

struct SMARTReadCompletionError: Codable, Equatable, Sendable {
    let code: SMARTReadCompletionErrorCode
    let message: String
}

struct SMARTCancelRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: String

    init(
        schemaVersion: Int = SMARTCancelRequest.currentSchemaVersion,
        requestID: String
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
    }
}

enum SMARTCancelResult: String, Codable, Equatable, Sendable {
    /// The helper accepted the cancellation signal. Process exit is proven by
    /// the separate completion envelope, not by this acknowledgement.
    case accepted
    case notFound
}

struct SMARTCancelAcknowledgement: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: String
    let result: SMARTCancelResult
}

enum SMARTXPCLimits {
    static let requestBytes = 4 * 1024
    static let payloadBytes = 2 * 1024 * 1024
    static let responseBytes = 3 * 1024 * 1024
    static let handshakeBytes = 4 * 1024
    static let cancelRequestBytes = 4 * 1024
    static let cancelResponseBytes = 4 * 1024
    static let errorMessageUTF8Bytes = 1 * 1024
    static let legacyCancelRequestUTF8Bytes = 64
}

struct SMARTCompanionInstallRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let binary: Data

    init(
        schemaVersion: Int = SMARTCompanionInstallRequest.currentSchemaVersion,
        binary: Data
    ) {
        self.schemaVersion = schemaVersion
        self.binary = binary
    }
}

enum SMARTCompanionInstallResult: String, Codable, Equatable, Sendable {
    case installed
}

struct SMARTCompanionInstallAcknowledgement: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let result: SMARTCompanionInstallResult
}

enum SMARTCompanionXPCLimits {
    static let binaryBytes = 8 * 1024 * 1024
    // JSON encodes Data as base64, so the envelope needs bounded expansion room.
    static let requestBytes = 11 * 1024 * 1024
    static let acknowledgementBytes = 4 * 1024
}

struct OccupancyScanRequest: Codable, Equatable, Sendable {
    let workflowID: UUID
    let physicalDeviceBSDName: String
}

struct OccupancyHolderMessage: Codable, Equatable, Sendable {
    let pid: Int32
    let executableName: String
    let displayName: String?
    let type: String
}

struct OccupancyScanResponse: Codable, Equatable, Sendable {
    let workflowID: UUID
    let holders: [OccupancyHolderMessage]
    let isComplete: Bool
}

enum OccupancyXPCLimits {
    static let requestBytes = 4 * 1024
    static let responseBytes = 64 * 1024
    static let maxHolders = 64
    static let maxCandidatePIDs = 4_096
    static let maxNameUTF8Bytes = 255
    /// Four holder categories per bounded PID candidate limits normalization work.
    static let maxInputHolders = maxCandidatePIDs * 4
    /// Rejects pathological strings before grapheme-cluster traversal.
    static let maxRawNameUTF8Bytes = 4 * 1024
}

struct XPCFeatureCapabilities: Equatable, Sendable {
    let completionAwareSMART: Bool
    let smartCancellation: Bool
    let observableSMARTFailures: Bool
    let smartctlCompanionInstallation: Bool
    let occupancyScanning: Bool

    init(
        completionAwareSMART: Bool,
        smartCancellation: Bool,
        observableSMARTFailures: Bool,
        smartctlCompanionInstallation: Bool = false,
        occupancyScanning: Bool
    ) {
        self.completionAwareSMART = completionAwareSMART
        self.smartCancellation = smartCancellation
        self.observableSMARTFailures = observableSMARTFailures
        self.smartctlCompanionInstallation = smartctlCompanionInstallation
        self.occupancyScanning = occupancyScanning
    }

    static func negotiated(helperContractMinor: Int) -> Self {
        let supportsMinorFour = helperContractMinor >= XPCContractVersion.completionAwareSMARTMinor
        return Self(
            completionAwareSMART: supportsMinorFour,
            smartCancellation: helperContractMinor >= XPCContractVersion.smartCancellationMinor,
            observableSMARTFailures: helperContractMinor >= XPCContractVersion.observableSMARTFailuresMinor,
            smartctlCompanionInstallation: helperContractMinor >= XPCContractVersion.smartctlCompanionInstallationMinor,
            occupancyScanning: supportsMinorFour
        )
    }
}

enum DrivePulseXPCMessageError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case processExitUnacknowledged
    case encodedMessageTooLarge
    case invalidSMARTMessage
    case invalidOccupancyMessage
}

enum DrivePulseXPCMessages {
    static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        try JSONEncoder().encode(message)
    }

    static func decode<Message: Decodable>(
        _ messageType: Message.Type,
        from data: Data
    ) throws -> Message {
        try JSONDecoder().decode(messageType, from: data)
    }

    static func encodeSMARTReadCompletionResponse(
        _ response: SMARTReadCompletionResponse
    ) throws -> Data {
        let response = try normalizedSMARTCompletionResponse(response)
        guard response.payload.count <= SMARTXPCLimits.payloadBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        let data = try encode(response)
        guard data.count <= SMARTXPCLimits.responseBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func decodeSMARTReadCompletionResponse(
        from data: Data
    ) throws -> SMARTReadCompletionResponse {
        guard data.count <= SMARTXPCLimits.responseBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        let response = try decode(SMARTReadCompletionResponse.self, from: data)
        guard response.schemaVersion == SMARTReadCompletionResponse.currentSchemaVersion else {
            throw DrivePulseXPCMessageError.unsupportedSchemaVersion(response.schemaVersion)
        }
        guard response.payload.count <= SMARTXPCLimits.payloadBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        try validateSMARTCompletionResponse(response)
        return response
    }

    static func decodeAcknowledgedSMARTReadCompletionResponse(
        from data: Data
    ) throws -> SMARTReadCompletionResponse {
        let response = try decodeSMARTReadCompletionResponse(from: data)
        guard response.processDidExit else {
            throw DrivePulseXPCMessageError.processExitUnacknowledged
        }
        return response
    }

    static func encodeSMARTCancelRequest(_ request: SMARTCancelRequest) throws -> Data {
        let request = try normalizedSMARTCancelRequest(request)
        let data = try encode(request)
        guard data.count <= SMARTXPCLimits.cancelRequestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func decodeSMARTCancelRequest(from data: Data) throws -> SMARTCancelRequest {
        guard data.count <= SMARTXPCLimits.cancelRequestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return try normalizedSMARTCancelRequest(decode(SMARTCancelRequest.self, from: data))
    }

    static func encodeSMARTCancelAcknowledgement(
        _ acknowledgement: SMARTCancelAcknowledgement
    ) throws -> Data {
        guard acknowledgement.schemaVersion == SMARTCancelAcknowledgement.currentSchemaVersion,
              let requestID = normalizedUUIDString(acknowledgement.requestID) else {
            throw DrivePulseXPCMessageError.invalidSMARTMessage
        }
        let normalized = SMARTCancelAcknowledgement(
            schemaVersion: acknowledgement.schemaVersion,
            requestID: requestID,
            result: acknowledgement.result
        )
        let data = try encode(normalized)
        guard data.count <= SMARTXPCLimits.cancelResponseBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func decodeSMARTCancelAcknowledgement(
        from data: Data
    ) throws -> SMARTCancelAcknowledgement {
        guard data.count <= SMARTXPCLimits.cancelResponseBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        let acknowledgement = try decode(SMARTCancelAcknowledgement.self, from: data)
        guard acknowledgement.schemaVersion == SMARTCancelAcknowledgement.currentSchemaVersion,
              let requestID = normalizedUUIDString(acknowledgement.requestID) else {
            throw DrivePulseXPCMessageError.invalidSMARTMessage
        }
        return SMARTCancelAcknowledgement(
            schemaVersion: acknowledgement.schemaVersion,
            requestID: requestID,
            result: acknowledgement.result
        )
    }

    static func encodeSMARTCompanionInstallRequest(
        _ request: SMARTCompanionInstallRequest
    ) throws -> Data {
        try validateSMARTCompanionInstallRequest(request)
        let data = try encode(request)
        guard data.count <= SMARTCompanionXPCLimits.requestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func decodeSMARTCompanionInstallRequest(
        from data: Data
    ) throws -> SMARTCompanionInstallRequest {
        guard data.count <= SMARTCompanionXPCLimits.requestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        let request = try decode(SMARTCompanionInstallRequest.self, from: data)
        try validateSMARTCompanionInstallRequest(request)
        return request
    }

    static func encodeSMARTCompanionInstallAcknowledgement(
        _ acknowledgement: SMARTCompanionInstallAcknowledgement
    ) throws -> Data {
        guard acknowledgement.schemaVersion == SMARTCompanionInstallAcknowledgement.currentSchemaVersion else {
            throw DrivePulseXPCMessageError.unsupportedSchemaVersion(acknowledgement.schemaVersion)
        }
        let data = try encode(acknowledgement)
        guard data.count <= SMARTCompanionXPCLimits.acknowledgementBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func decodeSMARTCompanionInstallAcknowledgement(
        from data: Data
    ) throws -> SMARTCompanionInstallAcknowledgement {
        guard data.count <= SMARTCompanionXPCLimits.acknowledgementBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        let acknowledgement = try decode(SMARTCompanionInstallAcknowledgement.self, from: data)
        guard acknowledgement.schemaVersion == SMARTCompanionInstallAcknowledgement.currentSchemaVersion else {
            throw DrivePulseXPCMessageError.unsupportedSchemaVersion(acknowledgement.schemaVersion)
        }
        return acknowledgement
    }

    static func encodeOccupancyRequest(_ request: OccupancyScanRequest) throws -> Data {
        let data = try encode(request)
        guard data.count <= OccupancyXPCLimits.requestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func encodeSMARTReadRequest(_ request: SMARTReadRequest) throws -> Data {
        try validateSMARTReadRequest(request)
        let data = try encode(request)
        guard data.count <= SMARTXPCLimits.requestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func decodeSMARTReadRequest(from data: Data) throws -> SMARTReadRequest {
        guard data.count <= SMARTXPCLimits.requestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        let request = try decode(SMARTReadRequest.self, from: data)
        try validateSMARTReadRequest(request)
        return request
    }

    static func validateSMARTPayload(_ payload: Data) throws {
        guard payload.isEmpty == false, payload.count <= SMARTXPCLimits.payloadBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
    }

    private static func validateSMARTReadRequest(_ request: SMARTReadRequest) throws {
        if let requestID = request.requestID, UUID(uuidString: requestID) == nil {
            throw DrivePulseXPCMessageError.invalidSMARTMessage
        }
    }

    private static func normalizedSMARTCompletionResponse(
        _ response: SMARTReadCompletionResponse
    ) throws -> SMARTReadCompletionResponse {
        let requestID: String?
        if let rawRequestID = response.requestID {
            guard UUID(uuidString: rawRequestID) != nil else {
                throw DrivePulseXPCMessageError.invalidSMARTMessage
            }
            // Echo the request identifier byte-for-byte so callers can bind a
            // completion to the exact request they sent. The helper registry
            // normalizes only its private lookup key.
            requestID = rawRequestID
        } else {
            requestID = nil
        }
        let error: SMARTReadCompletionError?
        if let rawError = response.error {
            error = SMARTReadCompletionError(
                code: rawError.code,
                message: truncatedUTF8(rawError.message, limit: SMARTXPCLimits.errorMessageUTF8Bytes)
            )
        } else {
            error = nil
        }
        let normalized = SMARTReadCompletionResponse(
            schemaVersion: response.schemaVersion,
            payload: response.payload,
            processDidExit: response.processDidExit,
            deviceSMARTIOQuiesced: response.deviceSMARTIOQuiesced,
            requestID: requestID,
            error: error
        )
        try validateSMARTCompletionResponse(normalized)
        return normalized
    }

    private static func validateSMARTCompletionResponse(
        _ response: SMARTReadCompletionResponse
    ) throws {
        guard response.requestID.map({ normalizedUUIDString($0) != nil }) ?? true,
              response.error?.message.utf8.count ?? 0 <= SMARTXPCLimits.errorMessageUTF8Bytes,
              response.error == nil || response.payload.isEmpty,
              response.deviceSMARTIOQuiesced != true || response.processDidExit else {
            throw DrivePulseXPCMessageError.invalidSMARTMessage
        }
    }

    private static func normalizedSMARTCancelRequest(
        _ request: SMARTCancelRequest
    ) throws -> SMARTCancelRequest {
        guard request.schemaVersion == SMARTCancelRequest.currentSchemaVersion,
              let requestID = normalizedUUIDString(request.requestID) else {
            throw DrivePulseXPCMessageError.invalidSMARTMessage
        }
        return SMARTCancelRequest(schemaVersion: request.schemaVersion, requestID: requestID)
    }

    private static func validateSMARTCompanionInstallRequest(
        _ request: SMARTCompanionInstallRequest
    ) throws {
        guard request.schemaVersion == SMARTCompanionInstallRequest.currentSchemaVersion else {
            throw DrivePulseXPCMessageError.unsupportedSchemaVersion(request.schemaVersion)
        }
        guard request.binary.isEmpty == false,
              request.binary.count <= SMARTCompanionXPCLimits.binaryBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
    }

    private static func normalizedUUIDString(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString.lowercased()
    }

    private static func truncatedUTF8(_ value: String, limit: Int) -> String {
        var result = ""
        var bytes = 0
        for scalar in value.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= limit else { break }
            result.unicodeScalars.append(scalar)
            bytes += scalarBytes
        }
        return result
    }

    static func decodeOccupancyRequest(from data: Data) throws -> OccupancyScanRequest {
        guard data.count <= OccupancyXPCLimits.requestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return try decode(OccupancyScanRequest.self, from: data)
    }

    static func encodeOccupancyResponse(_ response: OccupancyScanResponse) throws -> Data {
        guard response.holders.count <= OccupancyXPCLimits.maxInputHolders else {
            throw DrivePulseXPCMessageError.invalidOccupancyMessage
        }
        let normalized = OccupancyScanResponse(
            workflowID: response.workflowID,
            holders: try normalizedHolders(response.holders),
            isComplete: response.isComplete
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(normalized)
        guard data.count <= OccupancyXPCLimits.responseBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
    }

    static func decodeOccupancyResponse(from data: Data) throws -> OccupancyScanResponse {
        guard data.count <= OccupancyXPCLimits.responseBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        let response = try decode(OccupancyScanResponse.self, from: data)
        guard response.holders.count <= OccupancyXPCLimits.maxHolders,
              response.holders.allSatisfy(isValidDecodedHolder) else {
            throw DrivePulseXPCMessageError.invalidOccupancyMessage
        }
        return response
    }

    /// The legacy contract returns the helper payload without an envelope.
    static func legacySMARTReply(payload: Data) -> Data { payload }

    private static func normalizedHolders(
        _ holders: [OccupancyHolderMessage]
    ) throws -> [OccupancyHolderMessage] {
        var unique: [OccupancyHolderKey: OccupancyHolderMessage] = [:]
        for holder in holders {
            guard isValidRawName(holder.executableName),
                  holder.displayName.map(isValidRawName) ?? true else {
                throw DrivePulseXPCMessageError.invalidOccupancyMessage
            }
            let normalized = OccupancyHolderMessage(
                pid: holder.pid,
                executableName: truncatedName(holder.executableName),
                displayName: holder.displayName.map(truncatedName),
                type: holder.type
            )
            let key = OccupancyHolderKey(pid: holder.pid, type: holder.type)
            if let existing = unique[key] {
                if isPreferredDedupeWinner(normalized, over: existing) {
                    unique[key] = normalized
                }
            } else {
                unique[key] = normalized
            }
        }

        return unique.values.sorted(by: holderSort).prefix(OccupancyXPCLimits.maxHolders).map { $0 }
    }

    private static func truncatedName(_ name: String) -> String {
        var result = ""
        var byteCount = 0
        for character in name {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= OccupancyXPCLimits.maxNameUTF8Bytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        guard result.isEmpty else { return result }

        var scalarResult = String.UnicodeScalarView()
        byteCount = 0
        for scalar in name.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard byteCount + scalarBytes <= OccupancyXPCLimits.maxNameUTF8Bytes else { break }
            scalarResult.append(scalar)
            byteCount += scalarBytes
        }
        return String(scalarResult)
    }

    private static func isValidRawName(_ name: String) -> Bool {
        name.isEmpty == false && name.utf8.count <= OccupancyXPCLimits.maxRawNameUTF8Bytes
    }

    private static func isValidDecodedHolder(_ holder: OccupancyHolderMessage) -> Bool {
        isValidDecodedName(holder.executableName)
            && (holder.displayName.map(isValidDecodedName) ?? true)
    }

    private static func isValidDecodedName(_ name: String) -> Bool {
        name.isEmpty == false && name.utf8.count <= OccupancyXPCLimits.maxNameUTF8Bytes
    }

    private static func isPreferredDedupeWinner(
        _ candidate: OccupancyHolderMessage,
        over existing: OccupancyHolderMessage
    ) -> Bool {
        switch (candidate.displayName, existing.displayName) {
        case (.some, .none): return true
        case (.none, .some): return false
        case let (.some(candidateName), .some(existingName)) where candidateName != existingName:
            return candidateName < existingName
        default:
            return candidate.executableName < existing.executableName
        }
    }

    private static func holderSort(
        _ lhs: OccupancyHolderMessage,
        _ rhs: OccupancyHolderMessage
    ) -> Bool {
        let lhsName = lhs.displayName ?? lhs.executableName
        let rhsName = rhs.displayName ?? rhs.executableName
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.type < rhs.type
    }
}

private struct OccupancyHolderKey: Hashable {
    let pid: Int32
    let type: String
}
