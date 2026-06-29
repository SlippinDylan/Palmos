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
}
