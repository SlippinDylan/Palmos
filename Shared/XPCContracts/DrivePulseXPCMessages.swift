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

    /// The legacy contract returns the helper payload without an envelope.
    static func legacySMARTReply(payload: Data) -> Data { payload }
}
