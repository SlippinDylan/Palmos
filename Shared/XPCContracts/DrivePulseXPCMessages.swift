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
}
