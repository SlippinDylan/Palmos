import XCTest
@testable import DrivePulseCore

final class SmartDataParserTests: XCTestCase {
    func testParserExtractsHighestAndPrimaryTemperatures() throws {
        let jsonData = Data(
            #"{"temperature":{"current":47},"nvme_smart_health_information_log":{"temperature_sensors":[47,52]}}"#
                .utf8
        )

        let smartData = try SmartDataParser.parse(jsonData: jsonData)

        XCTAssertEqual(smartData.primaryTemperature, 47)
        XCTAssertEqual(smartData.highestTemperature, 52)
    }

    func testTransportHintResolverRecognizesThunderboltNVMeAsPassthroughCandidate() {
        XCTAssertEqual(
            TransportHintResolver.resolve(
                protocolName: "Thunderbolt 3",
                modelName: "TB406Pro"
            ),
            .autoPassthrough
        )
    }

    func testTransportHintResolverDoesNotTreatUSBModelMatchAsPassthroughCandidate() {
        XCTAssertEqual(
            TransportHintResolver.resolve(
                protocolName: "USB 3.2",
                modelName: "TB406Pro"
            ),
            .none
        )
    }

    func testSensorMaxWinsForOverviewDisplayWhenHighestTemperatureIsMissing() {
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 47,
            highestTemperature: nil,
            sensorTemperatures: [
                "Sensor 1": 47,
                "Sensor 2": 52
            ]
        )

        XCTAssertEqual(TemperatureSelection.overviewTemperature(for: smartData), 52)
    }

    func testHighestTemperatureOverridesSensorMaxForOverviewDisplay() {
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 47,
            highestTemperature: 55,
            sensorTemperatures: [
                "Sensor 1": 47,
                "Sensor 2": 52
            ]
        )

        XCTAssertEqual(TemperatureSelection.overviewTemperature(for: smartData), 55)
    }

    func testPrimaryTemperatureIsFallbackWhenHigherPrioritySourcesAreMissing() {
        let smartData = SmartData(
            overallHealth: "PASSED",
            primaryTemperature: 47,
            highestTemperature: nil,
            sensorTemperatures: [:]
        )

        XCTAssertEqual(TemperatureSelection.overviewTemperature(for: smartData), 47)
    }

    func testParserExtractsAllHealthLogFields() throws {
        let json = """
        {
          "smart_status": { "passed": true },
          "temperature": { "current": 48 },
          "wctemp": 84,
          "cctemp": 85,
          "nvme_smart_health_information_log": {
            "critical_warning": 0,
            "temperature": 48,
            "available_spare": 100,
            "available_spare_threshold": 10,
            "percentage_used": 3,
            "data_units_read": 86014906,
            "data_units_written": 89929541,
            "host_reads": 1319573770,
            "host_writes": 1326508306,
            "controller_busy_time": 2859,
            "power_cycles": 1837,
            "power_on_hours": 3833,
            "unsafe_shutdowns": 388,
            "media_errors": 0,
            "num_err_log_entries": 70088,
            "warning_temp_time": 0,
            "critical_comp_time": 0,
            "temperature_sensors": [48, 50]
          }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let result = try SmartDataParser.parse(jsonData: data)

        XCTAssertEqual(result.criticalWarning, 0)
        XCTAssertEqual(result.availableSpare, 100)
        XCTAssertEqual(result.availableSpareThreshold, 10)
        XCTAssertEqual(result.percentageUsed, 3)
        XCTAssertEqual(result.dataUnitsRead, 86014906)
        XCTAssertEqual(result.dataUnitsWritten, 89929541)
        XCTAssertEqual(result.hostReadCommands, 1319573770)
        XCTAssertEqual(result.hostWriteCommands, 1326508306)
        XCTAssertEqual(result.controllerBusyTime, 2859)
        XCTAssertEqual(result.powerCycles, 1837)
        XCTAssertEqual(result.powerOnHours, 3833)
        XCTAssertEqual(result.unsafeShutdowns, 388)
        XCTAssertEqual(result.mediaIntegrityErrors, 0)
        XCTAssertEqual(result.errorLogEntries, 70088)
        XCTAssertEqual(result.warningTempTime, 0)
        XCTAssertEqual(result.criticalTempTime, 0)
        XCTAssertEqual(result.warningTempThreshold, 84)
        XCTAssertEqual(result.criticalTempThreshold, 85)
    }

    func testParserReturnNilForMissingHealthLogFields() throws {
        let json = """
        {
          "smart_status": { "passed": true },
          "temperature": { "current": 35 }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let result = try SmartDataParser.parse(jsonData: data)

        XCTAssertNil(result.criticalWarning)
        XCTAssertNil(result.availableSpare)
        XCTAssertNil(result.availableSpareThreshold)
        XCTAssertNil(result.percentageUsed)
        XCTAssertNil(result.dataUnitsRead)
        XCTAssertNil(result.dataUnitsWritten)
        XCTAssertNil(result.hostReadCommands)
        XCTAssertNil(result.hostWriteCommands)
        XCTAssertNil(result.controllerBusyTime)
        XCTAssertNil(result.powerCycles)
        XCTAssertNil(result.powerOnHours)
        XCTAssertNil(result.unsafeShutdowns)
        XCTAssertNil(result.mediaIntegrityErrors)
        XCTAssertNil(result.errorLogEntries)
        XCTAssertNil(result.warningTempTime)
        XCTAssertNil(result.criticalTempTime)
        XCTAssertNil(result.warningTempThreshold)
        XCTAssertNil(result.criticalTempThreshold)
        XCTAssertEqual(result.primaryTemperature, 35)
    }

    func testParserAcceptsNumericStringsAndIgnoresOutOfRangeCounters() throws {
        let data = Data(
            """
            {
              "nvme_smart_health_information_log": {
                "data_units_read": "86014906",
                "data_units_written": 18446744073709551615,
                "power_cycles": 7
              }
            }
            """.utf8
        )

        let result = try SmartDataParser.parse(jsonData: data)

        XCTAssertEqual(result.dataUnitsRead, 86_014_906)
        XCTAssertNil(result.dataUnitsWritten)
        XCTAssertEqual(result.powerCycles, 7)
    }
}
