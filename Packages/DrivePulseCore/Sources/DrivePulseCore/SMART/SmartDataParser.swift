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
            sensorTemperatures: sensorTemperatures,
            criticalWarning: payload.nvmeSMARTHealthInformationLog?.criticalWarning,
            availableSpare: payload.nvmeSMARTHealthInformationLog?.availableSpare,
            availableSpareThreshold: payload.nvmeSMARTHealthInformationLog?.availableSpareThreshold,
            percentageUsed: payload.nvmeSMARTHealthInformationLog?.percentageUsed,
            dataUnitsRead: payload.nvmeSMARTHealthInformationLog?.dataUnitsRead,
            dataUnitsWritten: payload.nvmeSMARTHealthInformationLog?.dataUnitsWritten,
            hostReadCommands: payload.nvmeSMARTHealthInformationLog?.hostReads,
            hostWriteCommands: payload.nvmeSMARTHealthInformationLog?.hostWrites,
            controllerBusyTime: payload.nvmeSMARTHealthInformationLog?.controllerBusyTime,
            powerCycles: payload.nvmeSMARTHealthInformationLog?.powerCycles,
            powerOnHours: payload.nvmeSMARTHealthInformationLog?.powerOnHours,
            unsafeShutdowns: payload.nvmeSMARTHealthInformationLog?.unsafeShutdowns,
            mediaIntegrityErrors: payload.nvmeSMARTHealthInformationLog?.mediaErrors,
            errorLogEntries: payload.nvmeSMARTHealthInformationLog?.numErrLogEntries,
            warningTempTime: payload.nvmeSMARTHealthInformationLog?.warningTempTime,
            criticalTempTime: payload.nvmeSMARTHealthInformationLog?.criticalCompTime,
            warningTempThreshold: payload.wctemp,
            criticalTempThreshold: payload.cctemp
        )
    }
}

private struct SmartctlPayload: Decodable {
    let smartStatus: SmartStatus?
    let temperature: TemperatureReading?
    let nvmeSMARTHealthInformationLog: NVMESMARTHealthInformationLog?
    let wctemp: Int?
    let cctemp: Int?

    enum CodingKeys: String, CodingKey {
        case smartStatus = "smart_status"
        case temperature
        case nvmeSMARTHealthInformationLog = "nvme_smart_health_information_log"
        case wctemp
        case cctemp
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
    let criticalWarning: Int?
    let availableSpare: Int?
    let availableSpareThreshold: Int?
    let percentageUsed: Int?
    let dataUnitsRead: UInt64?
    let dataUnitsWritten: UInt64?
    let hostReads: UInt64?
    let hostWrites: UInt64?
    let controllerBusyTime: UInt64?
    let powerCycles: UInt64?
    let powerOnHours: UInt64?
    let unsafeShutdowns: UInt64?
    let mediaErrors: UInt64?
    let numErrLogEntries: UInt64?
    let warningTempTime: UInt64?
    let criticalCompTime: UInt64?

    enum CodingKeys: String, CodingKey {
        case temperature
        case temperatureSensors = "temperature_sensors"
        case criticalWarning = "critical_warning"
        case availableSpare = "available_spare"
        case availableSpareThreshold = "available_spare_threshold"
        case percentageUsed = "percentage_used"
        case dataUnitsRead = "data_units_read"
        case dataUnitsWritten = "data_units_written"
        case hostReads = "host_reads"
        case hostWrites = "host_writes"
        case controllerBusyTime = "controller_busy_time"
        case powerCycles = "power_cycles"
        case powerOnHours = "power_on_hours"
        case unsafeShutdowns = "unsafe_shutdowns"
        case mediaErrors = "media_errors"
        case numErrLogEntries = "num_err_log_entries"
        case warningTempTime = "warning_temp_time"
        case criticalCompTime = "critical_comp_time"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperature = container.decodeFlexibleIntIfPresent(forKey: .temperature)
        temperatureSensors = try container.decodeIfPresent([Int].self, forKey: .temperatureSensors) ?? []
        criticalWarning = container.decodeFlexibleIntIfPresent(forKey: .criticalWarning)
        availableSpare = container.decodeFlexibleIntIfPresent(forKey: .availableSpare)
        availableSpareThreshold = container.decodeFlexibleIntIfPresent(forKey: .availableSpareThreshold)
        percentageUsed = container.decodeFlexibleIntIfPresent(forKey: .percentageUsed)
        dataUnitsRead = container.decodeFlexibleUInt64IfPresent(forKey: .dataUnitsRead)
        dataUnitsWritten = container.decodeFlexibleUInt64IfPresent(forKey: .dataUnitsWritten)
        hostReads = container.decodeFlexibleUInt64IfPresent(forKey: .hostReads)
        hostWrites = container.decodeFlexibleUInt64IfPresent(forKey: .hostWrites)
        controllerBusyTime = container.decodeFlexibleUInt64IfPresent(forKey: .controllerBusyTime)
        powerCycles = container.decodeFlexibleUInt64IfPresent(forKey: .powerCycles)
        powerOnHours = container.decodeFlexibleUInt64IfPresent(forKey: .powerOnHours)
        unsafeShutdowns = container.decodeFlexibleUInt64IfPresent(forKey: .unsafeShutdowns)
        mediaErrors = container.decodeFlexibleUInt64IfPresent(forKey: .mediaErrors)
        numErrLogEntries = container.decodeFlexibleUInt64IfPresent(forKey: .numErrLogEntries)
        warningTempTime = container.decodeFlexibleUInt64IfPresent(forKey: .warningTempTime)
        criticalCompTime = container.decodeFlexibleUInt64IfPresent(forKey: .criticalCompTime)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleIntIfPresent(forKey key: Key) -> Int? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let string = try? decode(String.self, forKey: key) {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func decodeFlexibleUInt64IfPresent(forKey key: Key) -> UInt64? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let value = try? decode(UInt64.self, forKey: key) {
            return value
        }
        if let string = try? decode(String.self, forKey: key) {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
