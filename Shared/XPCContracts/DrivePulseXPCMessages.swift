import Foundation

struct HelperHandshake: Codable, Equatable, Sendable {
    let helperVersion: String
    let contractMajor: Int
    let contractMinor: Int
}

struct SMARTReadRequest: Codable, Equatable, Sendable {
    let physicalDeviceBSDName: String
    let deviceProtocol: String?
    let deviceModel: String?
}

struct SMARTReadCompletionResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let payload: Data
    let processDidExit: Bool
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
    let occupancyScanning: Bool

    static func negotiated(helperContractMinor: Int) -> Self {
        let supportsMinorFour = helperContractMinor >= XPCContractVersion.completionAwareSMARTMinor
        return Self(
            completionAwareSMART: supportsMinorFour,
            occupancyScanning: supportsMinorFour
        )
    }
}

enum DrivePulseXPCMessageError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case processExitUnacknowledged
    case encodedMessageTooLarge
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
        try encode(response)
    }

    static func decodeSMARTReadCompletionResponse(
        from data: Data
    ) throws -> SMARTReadCompletionResponse {
        let response = try decode(SMARTReadCompletionResponse.self, from: data)
        guard response.schemaVersion == SMARTReadCompletionResponse.currentSchemaVersion else {
            throw DrivePulseXPCMessageError.unsupportedSchemaVersion(response.schemaVersion)
        }
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

    static func encodeOccupancyRequest(_ request: OccupancyScanRequest) throws -> Data {
        let data = try encode(request)
        guard data.count <= OccupancyXPCLimits.requestBytes else {
            throw DrivePulseXPCMessageError.encodedMessageTooLarge
        }
        return data
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
        return result
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
