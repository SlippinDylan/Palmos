import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class ThroughputChartModelTests: XCTestCase {
    func testChartModelRightAlignsShortHistoryWithinVisibleWindow() {
        let metrics = DeviceSessionMetrics(
            currentReadBytesPerSecond: 0,
            currentWriteBytesPerSecond: 0,
            cumulativeReadBytes: 0,
            cumulativeWriteBytes: 0,
            readHistory: [
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 10), bytesPerSecond: 8_000),
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 11), bytesPerSecond: 12_000)
            ],
            writeHistory: []
        )

        let model = ThroughputChartModel(metrics: metrics)

        XCTAssertEqual(model.readSamples.count, ThroughputChartModel.visibleSampleCount)
        XCTAssertEqual(model.readSamples.dropLast(2).compactMap { $0 }.count, 0)
        XCTAssertEqual(model.readSamples.suffix(2).compactMap { $0 }, [8_000, 12_000])
    }

    func testChartModelUsesSharedPeakAcrossReadAndWrite() {
        let metrics = DeviceSessionMetrics(
            currentReadBytesPerSecond: 0,
            currentWriteBytesPerSecond: 0,
            cumulativeReadBytes: 0,
            cumulativeWriteBytes: 0,
            readHistory: [
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 10), bytesPerSecond: 8_000),
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 11), bytesPerSecond: 12_000)
            ],
            writeHistory: [
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 10), bytesPerSecond: 120),
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 11), bytesPerSecond: 240)
            ]
        )

        let model = ThroughputChartModel(metrics: metrics)

        XCTAssertEqual(model.chartPeakBytesPerSecond, 12_000)
    }

    func testChartModelPreservesRawHistoryValuesForStatsStyleRendering() {
        let timestamps = (0..<4).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let metrics = DeviceSessionMetrics(
            currentReadBytesPerSecond: 0,
            currentWriteBytesPerSecond: 0,
            cumulativeReadBytes: 0,
            cumulativeWriteBytes: 0,
            readHistory: [
                SpeedPoint(timestamp: timestamps[0], bytesPerSecond: 0),
                SpeedPoint(timestamp: timestamps[1], bytesPerSecond: 30),
                SpeedPoint(timestamp: timestamps[2], bytesPerSecond: 60),
                SpeedPoint(timestamp: timestamps[3], bytesPerSecond: 90)
            ],
            writeHistory: []
        )

        let model = ThroughputChartModel(metrics: metrics)

        XCTAssertEqual(model.readSamples.suffix(4).compactMap { $0 }, [0, 30, 60, 90])
    }

    func testZeroHistoryDoesNotProduceVisibleSeries() {
        let model = ThroughputChartModel(metrics: DeviceSessionMetrics(
            currentReadBytesPerSecond: 0,
            currentWriteBytesPerSecond: 0,
            cumulativeReadBytes: 0,
            cumulativeWriteBytes: 0,
            readHistory: [],
            writeHistory: []
        ))

        XCTAssertFalse(model.hasVisibleReadSeries)
        XCTAssertFalse(model.hasVisibleWriteSeries)
    }

    func testZeroThroughputSamplesStillProduceVisibleSeriesOnceHistoryExists() {
        let model = ThroughputChartModel(metrics: DeviceSessionMetrics(
            currentReadBytesPerSecond: 0,
            currentWriteBytesPerSecond: 0,
            cumulativeReadBytes: 0,
            cumulativeWriteBytes: 0,
            readHistory: [
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 10), bytesPerSecond: 0),
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 11), bytesPerSecond: 0),
                SpeedPoint(timestamp: Date(timeIntervalSince1970: 12), bytesPerSecond: 0)
            ],
            writeHistory: []
        ))

        XCTAssertTrue(model.hasVisibleReadSeries)
        XCTAssertFalse(model.hasVisibleWriteSeries)
    }
}
