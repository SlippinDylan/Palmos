import Foundation

public enum SmartctlTransportHint: Equatable, Sendable {
    case none
    case autoPassthrough

    public var smartctlDeviceArgument: String? {
        switch self {
        case .none:
            return nil
        case .autoPassthrough:
            return "nvme"
        }
    }
}

public enum TransportHintResolver {
    public static func resolve(
        protocolName: String?,
        modelName: String?
    ) -> SmartctlTransportHint {
        guard let normalizedProtocol = normalize(protocolName),
              normalizedProtocol.contains("thunderbolt") else {
            return .none
        }

        guard let normalizedModel = normalize(modelName) else {
            return .none
        }

        let passthroughModelHints = [
            "tb406pro"
        ]

        if passthroughModelHints.contains(where: normalizedModel.contains) {
            return .autoPassthrough
        }

        return .none
    }

    private static func normalize(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let normalized, normalized.isEmpty == false else {
            return nil
        }

        return normalized
    }
}

public enum SmartDataParser {
    public static func parse(jsonData: Data) throws -> SmartData {
        let payload = try JSONDecoder().decode(SmartctlPayload.self, from: jsonData)

        let primaryTemperature = payload.temperature?.current
            ?? payload.nvmeSMARTHealthInformationLog?.temperature
            ?? payload.nvmeSMARTHealthInformationLog?.temperatureSensors.first

        let sensorTemperatures = Dictionary(
            uniqueKeysWithValues: payload.nvmeSMARTHealthInformationLog?
                .temperatureSensors
                .enumerated()
                .map { index, value in
                    ("Sensor \(index + 1)", value)
                } ?? []
        )

        return SmartData(
            overallHealth: payload.smartStatus.map { $0.passed ? "PASSED" : "FAILED" },
            primaryTemperature: primaryTemperature,
            highestTemperature: ([primaryTemperature].compactMap { $0 } + sensorTemperatures.values).max(),
            sensorTemperatures: sensorTemperatures
        )
    }
}

private struct SmartctlPayload: Decodable {
    let smartStatus: SmartStatus?
    let temperature: TemperatureReading?
    let nvmeSMARTHealthInformationLog: NVMESMARTHealthInformationLog?

    enum CodingKeys: String, CodingKey {
        case smartStatus = "smart_status"
        case temperature
        case nvmeSMARTHealthInformationLog = "nvme_smart_health_information_log"
    }
}

private struct SmartStatus: Decodable {
    let passed: Bool
}

private struct TemperatureReading: Decodable {
    let current: Int?
}

private struct NVMESMARTHealthInformationLog: Decodable {
    let temperature: Int?
    let temperatureSensors: [Int]

    enum CodingKeys: String, CodingKey {
        case temperature
        case temperatureSensors = "temperature_sensors"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try container.decodeIfPresent(Int.self, forKey: .temperature)
        temperatureSensors = try container.decodeIfPresent([Int].self, forKey: .temperatureSensors) ?? []
    }
}
