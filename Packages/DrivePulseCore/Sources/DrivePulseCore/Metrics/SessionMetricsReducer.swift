import Foundation

public struct SessionMetricsReducer {
    public private(set) var metrics: DeviceSessionMetrics

    private let historyLimit: Int
    private var lastTimestamp: Date?

    public init(historyLimit: Int) {
        self.historyLimit = max(historyLimit, 0)
        self.metrics = .empty()
    }

    public mutating func ingest(readBytes: Int64, writeBytes: Int64, at timestamp: Date) {
        let normalizedReadBytes = max(readBytes, 0)
        let normalizedWriteBytes = max(writeBytes, 0)
        let sample = ThroughputSample(
            readBytes: normalizedReadBytes,
            writeBytes: normalizedWriteBytes,
            at: timestamp,
            previousTimestamp: lastTimestamp
        )

        metrics.currentReadBytesPerSecond = sample.readBytesPerSecond
        metrics.currentWriteBytesPerSecond = sample.writeBytesPerSecond
        metrics.cumulativeReadBytes = saturatingAdd(
            metrics.cumulativeReadBytes,
            sample.readBytes
        )
        metrics.cumulativeWriteBytes = saturatingAdd(
            metrics.cumulativeWriteBytes,
            sample.writeBytes
        )
        metrics.readHistory.append(sample.readPoint)
        metrics.writeHistory.append(sample.writePoint)
        metrics.readHistory = Array(metrics.readHistory.suffix(historyLimit))
        metrics.writeHistory = Array(metrics.writeHistory.suffix(historyLimit))
        lastTimestamp = timestamp
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
