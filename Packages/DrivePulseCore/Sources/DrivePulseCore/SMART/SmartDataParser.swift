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
            overallHealth: payload.smartStatus.map { $0 ? .passed : .failed },
            parsingQuality: payload.issues.isEmpty ? .clean : .degraded(payload.issues),
            primaryTemperature: primaryTemperature,
            highestTemperature: ([primaryTemperature].compactMap { $0 } + sensorTemperatures.values).max(),
            sensorTemperatures: sensorTemperatures,
            criticalWarning: payload.nvmeSMARTHealthInformationLog?.criticalWarning.value,
            availableSpare: payload.nvmeSMARTHealthInformationLog?.availableSpare.value,
            availableSpareThreshold: payload.nvmeSMARTHealthInformationLog?.availableSpareThreshold.value,
            percentageUsed: payload.nvmeSMARTHealthInformationLog?.percentageUsed.value,
            dataUnitsRead: payload.nvmeSMARTHealthInformationLog?.dataUnitsRead.value,
            dataUnitsWritten: payload.nvmeSMARTHealthInformationLog?.dataUnitsWritten.value,
            hostReadCommands: payload.nvmeSMARTHealthInformationLog?.hostReads.value,
            hostWriteCommands: payload.nvmeSMARTHealthInformationLog?.hostWrites.value,
            controllerBusyTime: payload.nvmeSMARTHealthInformationLog?.controllerBusyTime.value,
            powerCycles: payload.nvmeSMARTHealthInformationLog?.powerCycles.value,
            powerOnHours: payload.nvmeSMARTHealthInformationLog?.powerOnHours.value,
            unsafeShutdowns: payload.nvmeSMARTHealthInformationLog?.unsafeShutdowns.value,
            mediaIntegrityErrors: payload.nvmeSMARTHealthInformationLog?.mediaErrors.value,
            errorLogEntries: payload.nvmeSMARTHealthInformationLog?.numErrLogEntries.value,
            warningTempTime: payload.nvmeSMARTHealthInformationLog?.warningTempTime.value,
            criticalTempTime: payload.nvmeSMARTHealthInformationLog?.criticalCompTime.value,
            warningTempThreshold: payload.wctemp,
            criticalTempThreshold: payload.cctemp
        )
    }
}

private struct SmartctlPayload: Decodable {
    let smartStatus: Bool?
    let temperature: TemperatureReading?
    let nvmeSMARTHealthInformationLog: NVMESMARTHealthInformationLog?
    let wctemp: Int?
    let cctemp: Int?
    let issues: [SmartDataParseIssue]

    enum CodingKeys: String, CodingKey {
        case smartStatus = "smart_status"
        case temperature
        case nvmeSMARTHealthInformationLog = "nvme_smart_health_information_log"
        case wctemp
        case cctemp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var diagnostics: [SmartDataParseIssue] = []

        let health: ParsedField<Bool>
        if container.contains(.smartStatus), (try? container.decodeNil(forKey: .smartStatus)) != true {
            do {
                let nested = try container.nestedContainer(keyedBy: SmartStatusCodingKeys.self, forKey: .smartStatus)
                if nested.contains(.passed), (try? nested.decodeNil(forKey: .passed)) != true {
                    health = ParsedField(value: try nested.decode(Bool.self, forKey: .passed), issues: [])
                } else {
                    health = ParsedField(value: nil, issues: [])
                }
            } catch {
                health = ParsedField(value: nil, issues: [.init(field: .overallHealth, reason: .typeMismatch)])
            }
        } else {
            health = ParsedField(value: nil, issues: [])
        }
        smartStatus = health.value
        diagnostics.append(contentsOf: health.issues)

        if container.contains(.temperature), (try? container.decodeNil(forKey: .temperature)) != true {
            do {
                temperature = try container.decode(TemperatureReading.self, forKey: .temperature)
                diagnostics.append(contentsOf: temperature?.issues ?? [])
            } catch {
                temperature = nil
                diagnostics.append(.init(field: .primaryTemperature, reason: .typeMismatch))
            }
        } else {
            temperature = nil
        }

        if container.contains(.nvmeSMARTHealthInformationLog), (try? container.decodeNil(forKey: .nvmeSMARTHealthInformationLog)) != true {
            do {
                nvmeSMARTHealthInformationLog = try container.decode(NVMESMARTHealthInformationLog.self, forKey: .nvmeSMARTHealthInformationLog)
                diagnostics.append(contentsOf: nvmeSMARTHealthInformationLog?.issues ?? [])
            } catch {
                nvmeSMARTHealthInformationLog = nil
                diagnostics.append(.init(field: .nvmeHealthLog, reason: .typeMismatch))
            }
        } else {
            nvmeSMARTHealthInformationLog = nil
        }

        let warning = container.decodeFlexibleIntIfPresent(forKey: .wctemp, field: .warningTempThreshold)
        wctemp = warning.value
        diagnostics.append(contentsOf: warning.issues)
        let critical = container.decodeFlexibleIntIfPresent(forKey: .cctemp, field: .criticalTempThreshold)
        cctemp = critical.value
        diagnostics.append(contentsOf: critical.issues)
        issues = diagnostics.sorted { $0.field.rawValue < $1.field.rawValue }
    }
}

private struct TemperatureReading: Decodable {
    let current: Int?
    let issues: [SmartDataParseIssue]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CurrentCodingKeys.self)
        let result = container.decodeFlexibleIntIfPresent(forKey: .current, field: .primaryTemperature)
        current = result.value
        issues = result.issues
    }

    private enum CurrentCodingKeys: String, CodingKey { case current }
}

private struct NVMESMARTHealthInformationLog: Decodable {
    let temperature: Int?
    let temperatureSensors: [Int]
    let criticalWarning: ParsedField<Int>
    let availableSpare: ParsedField<Int>
    let availableSpareThreshold: ParsedField<Int>
    let percentageUsed: ParsedField<Int>
    let dataUnitsRead: ParsedField<UInt64>
    let dataUnitsWritten: ParsedField<UInt64>
    let hostReads: ParsedField<UInt64>
    let hostWrites: ParsedField<UInt64>
    let controllerBusyTime: ParsedField<UInt64>
    let powerCycles: ParsedField<UInt64>
    let powerOnHours: ParsedField<UInt64>
    let unsafeShutdowns: ParsedField<UInt64>
    let mediaErrors: ParsedField<UInt64>
    let numErrLogEntries: ParsedField<UInt64>
    let warningTempTime: ParsedField<UInt64>
    let criticalCompTime: ParsedField<UInt64>
    let issues: [SmartDataParseIssue]

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
        let temperatureResult = container.decodeFlexibleIntIfPresent(forKey: .temperature, field: .nvmeTemperature)
        temperature = temperatureResult.value
        var diagnostics = temperatureResult.issues
        if container.contains(.temperatureSensors), (try? container.decodeNil(forKey: .temperatureSensors)) != true {
            do {
                temperatureSensors = try container.decode([Int].self, forKey: .temperatureSensors)
            } catch {
                temperatureSensors = []
                diagnostics.append(.init(field: .sensorTemperatures, reason: .typeMismatch))
            }
        } else {
            temperatureSensors = []
        }
        criticalWarning = container.decodeFlexibleIntIfPresent(forKey: .criticalWarning, field: .criticalWarning)
        availableSpare = container.decodeFlexibleIntIfPresent(forKey: .availableSpare, field: .availableSpare)
        availableSpareThreshold = container.decodeFlexibleIntIfPresent(forKey: .availableSpareThreshold, field: .availableSpareThreshold)
        percentageUsed = container.decodeFlexibleIntIfPresent(forKey: .percentageUsed, field: .percentageUsed)
        dataUnitsRead = container.decodeFlexibleUInt64IfPresent(forKey: .dataUnitsRead, field: .dataUnitsRead)
        dataUnitsWritten = container.decodeFlexibleUInt64IfPresent(forKey: .dataUnitsWritten, field: .dataUnitsWritten)
        hostReads = container.decodeFlexibleUInt64IfPresent(forKey: .hostReads, field: .hostReadCommands)
        hostWrites = container.decodeFlexibleUInt64IfPresent(forKey: .hostWrites, field: .hostWriteCommands)
        controllerBusyTime = container.decodeFlexibleUInt64IfPresent(forKey: .controllerBusyTime, field: .controllerBusyTime)
        powerCycles = container.decodeFlexibleUInt64IfPresent(forKey: .powerCycles, field: .powerCycles)
        powerOnHours = container.decodeFlexibleUInt64IfPresent(forKey: .powerOnHours, field: .powerOnHours)
        unsafeShutdowns = container.decodeFlexibleUInt64IfPresent(forKey: .unsafeShutdowns, field: .unsafeShutdowns)
        mediaErrors = container.decodeFlexibleUInt64IfPresent(forKey: .mediaErrors, field: .mediaIntegrityErrors)
        numErrLogEntries = container.decodeFlexibleUInt64IfPresent(forKey: .numErrLogEntries, field: .errorLogEntries)
        warningTempTime = container.decodeFlexibleUInt64IfPresent(forKey: .warningTempTime, field: .warningTempTime)
        criticalCompTime = container.decodeFlexibleUInt64IfPresent(forKey: .criticalCompTime, field: .criticalTempTime)
        issues = [diagnostics, criticalWarning.issues, availableSpare.issues, availableSpareThreshold.issues,
                  percentageUsed.issues, dataUnitsRead.issues, dataUnitsWritten.issues,
                  hostReads.issues, hostWrites.issues, controllerBusyTime.issues, powerCycles.issues,
                  powerOnHours.issues, unsafeShutdowns.issues, mediaErrors.issues,
                  numErrLogEntries.issues, warningTempTime.issues, criticalCompTime.issues]
            .flatMap { $0 }
    }
}

private struct ParsedField<Value> {
    let value: Value?
    let issues: [SmartDataParseIssue]
}

private extension KeyedDecodingContainer {
    func decodeFlexibleIntIfPresent(forKey key: Key, field: SmartDataField) -> ParsedField<Int> {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return ParsedField(value: nil, issues: [])
        }
        if let value = try? decode(Int.self, forKey: key) {
            return ParsedField(value: value, issues: [])
        }
        if let string = try? decode(String.self, forKey: key) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(trimmed) {
                return ParsedField(value: value, issues: [])
            }
            let reason: SmartDataParseIssueReason = isDecimalDigits(trimmed) ? .outOfRange : .invalidNumericString
            return ParsedField(value: nil, issues: [.init(field: field, reason: reason)])
        }
        if (try? decode(Double.self, forKey: key)) != nil {
            return ParsedField(value: nil, issues: [.init(field: field, reason: .outOfRange)])
        }
        return ParsedField(value: nil, issues: [.init(field: field, reason: .typeMismatch)])
    }

    func decodeFlexibleUInt64IfPresent(forKey key: Key, field: SmartDataField) -> ParsedField<UInt64> {
        guard contains(key), (try? decodeNil(forKey: key)) != true else {
            return ParsedField(value: nil, issues: [])
        }
        if let value = try? decode(UInt64.self, forKey: key) {
            return ParsedField(value: value, issues: [])
        }
        if let string = try? decode(String.self, forKey: key) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = UInt64(trimmed) {
                return ParsedField(value: value, issues: [])
            }
            let reason: SmartDataParseIssueReason = isUnsignedDecimalDigits(trimmed) || trimmed.hasPrefix("-")
                ? .outOfRange
                : .invalidNumericString
            return ParsedField(value: nil, issues: [.init(field: field, reason: reason)])
        }
        if (try? decode(Double.self, forKey: key)) != nil {
            return ParsedField(value: nil, issues: [.init(field: field, reason: .outOfRange)])
        }
        return ParsedField(value: nil, issues: [.init(field: field, reason: .typeMismatch)])
    }

    private func isDecimalDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isNumber || $0 == "-" || $0 == "+" }
    }

    private func isUnsignedDecimalDigits(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}

private enum SmartStatusCodingKeys: String, CodingKey { case passed }
