import XCTest
@testable import DrivePulseCore

final class SmartDataParserTests: XCTestCase {
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
