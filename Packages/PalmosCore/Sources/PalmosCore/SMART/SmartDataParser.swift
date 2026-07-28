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
    public static func parseReport(jsonData: Data) throws -> SmartReport {
        let base = try parseBase(jsonData: jsonData)
        let supplemental = try SupplementalSMARTParser.parse(jsonData: jsonData)
        var report = base.report
        report.capabilityMetadata = supplemental.capabilityMetadata
        report.errorHistory = supplemental.errorHistory
        report.selfTestHistory = supplemental.selfTestHistory
        return report
    }

    public static func parse(jsonData: Data) throws -> SmartData {
        SmartData(report: try parseReport(jsonData: jsonData))
    }

    private static func parseBase(jsonData: Data) throws -> SmartData {
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

private enum SupplementalSMARTParser {
    struct Result {
        let capabilityMetadata: SmartReportSection<SmartCapabilityReport>
        let errorHistory: SmartReportSection<SmartErrorHistoryReport>
        let selfTestHistory: SmartReportSection<SmartSelfTestHistoryReport>
    }

    static func parse(jsonData: Data) throws -> Result {
        let object = try JSONSerialization.jsonObject(with: jsonData)
        guard let root = object as? [String: Any] else {
            return Result(
                capabilityMetadata: .unsupported,
                errorHistory: .unsupported,
                selfTestHistory: .unsupported
            )
        }

        let capabilityJSON = canonicalJSON(from: root, keys: capabilityKeys)
        let smartSupport = root["smart_support"] as? [String: Any]
        let capability = SmartCapabilityReport(
            modelFamily: root["model_family"] as? String,
            modelName: root["model_name"] as? String,
            serialNumber: root["serial_number"] as? String,
            firmwareVersion: root["firmware_version"] as? String,
            smartAvailable: smartSupport?["available"] as? Bool,
            smartEnabled: smartSupport?["enabled"] as? Bool,
            detailsJSON: capabilityJSON
        )

        let errorJSON = canonicalJSON(from: root, keys: errorHistoryKeys)
        let errorHistory = SmartErrorHistoryReport(
            loggedErrorCount: errorCount(in: root),
            detailsJSON: errorJSON
        )

        let selfTestJSON = canonicalJSON(from: root, keys: selfTestHistoryKeys)
        let selfTestEntries = selfTestRecords(in: root)
        let selfTestHistory = SmartSelfTestHistoryReport(
            recordedTestCount: selfTestEntries?.count,
            latestStatus: selfTestEntries.flatMap(latestSelfTestStatus),
            detailsJSON: selfTestJSON
        )

        return Result(
            capabilityMetadata: capabilityJSON == nil ? .unsupported : .available(capability),
            errorHistory: errorJSON == nil ? .unsupported : .available(errorHistory),
            selfTestHistory: selfTestJSON == nil ? .unsupported : .available(selfTestHistory)
        )
    }

    private static let capabilityKeys = [
        "device", "model_family", "model_name", "serial_number", "firmware_version",
        "rotation_rate", "form_factor", "smart_support", "ata_smart_data",
    ]
    private static let errorHistoryKeys = [
        "ata_smart_error_log", "nvme_error_information_log", "scsi_error_counter_log",
        "scsi_grown_defect_list",
    ]
    private static let selfTestHistoryKeys = [
        "ata_smart_self_test_log", "nvme_self_test_log", "scsi_self_test_log",
    ]

    private static func canonicalJSON(from root: [String: Any], keys: [String]) -> Data? {
        let selected = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            root[key].map { (key, $0) }
        })
        guard selected.isEmpty == false else { return nil }
        return try? JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys])
    }

    private static func errorCount(in root: [String: Any]) -> UInt64? {
        if let entries = root["nvme_error_information_log"] as? [Any] {
            return UInt64(entries.count)
        }
        guard let log = root["ata_smart_error_log"] as? [String: Any],
              let summary = log["summary"] as? [String: Any] else {
            return nil
        }
        return unsignedInteger(summary["count"])
    }

    private static func selfTestRecords(in root: [String: Any]) -> [[String: Any]]? {
        if let nvme = root["nvme_self_test_log"] as? [String: Any],
           let table = nvme["table"] as? [[String: Any]] {
            return table
        }
        if let ata = root["ata_smart_self_test_log"] as? [String: Any] {
            for name in ["standard", "extended"] {
                if let log = ata[name] as? [String: Any],
                   let table = log["table"] as? [[String: Any]] {
                    return table
                }
            }
        }
        if let scsi = root["scsi_self_test_log"] as? [[String: Any]] {
            return scsi
        }
        return nil
    }

    private static func latestSelfTestStatus(from entries: [[String: Any]]) -> String? {
        guard let first = entries.first else { return nil }
        if let status = first["status"] as? [String: Any] {
            return status["string"] as? String
        }
        return first["status"] as? String
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
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
