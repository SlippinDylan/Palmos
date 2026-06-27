import Foundation

public struct SessionMetricsReducer {
    public private(set) var metrics: DeviceSessionMetrics

    private let historyLimit: Int
    private var lastTimestamp: Date?

    public init(historyLimit: Int) {
        self.historyLimit = max(historyLimit, 0)
        self.metrics = .empty(historyLimit: historyLimit)
    }

    public mutating func ingest(readBytes: Int64, writeBytes: Int64, at timestamp: Date) {
        let sample = ThroughputSample(
            readBytes: readBytes,
            writeBytes: writeBytes,
            at: timestamp,
            previousTimestamp: lastTimestamp
        )

        metrics.currentReadBytesPerSecond = sample.readBytesPerSecond
        metrics.currentWriteBytesPerSecond = sample.writeBytesPerSecond
        metrics.cumulativeReadBytes += sample.readBytes
        metrics.cumulativeWriteBytes += sample.writeBytes
        metrics.readHistory.append(sample.readPoint)
        metrics.writeHistory.append(sample.writePoint)
        metrics.readHistory = Array(metrics.readHistory.suffix(historyLimit))
        metrics.writeHistory = Array(metrics.writeHistory.suffix(historyLimit))
        lastTimestamp = timestamp
    }
}
