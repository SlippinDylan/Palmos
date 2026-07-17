import Foundation

struct ThroughputSample {
    let timestamp: Date
    let readBytes: Int64
    let writeBytes: Int64
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    init(readBytes: Int64, writeBytes: Int64, at timestamp: Date, previousTimestamp: Date?) {
        let interval: TimeInterval
        if let previousTimestamp {
            let measuredInterval = timestamp.timeIntervalSince(previousTimestamp)
            interval = measuredInterval > 0 ? measuredInterval : 1
        } else {
            interval = 1
        }

        self.timestamp = timestamp
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        let readRate = Double(readBytes) / interval
        let writeRate = Double(writeBytes) / interval
        self.readBytesPerSecond = readRate.isFinite ? readRate : Double.greatestFiniteMagnitude
        self.writeBytesPerSecond = writeRate.isFinite ? writeRate : Double.greatestFiniteMagnitude
    }

    var readPoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: readBytesPerSecond)
    }

    var writePoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: writeBytesPerSecond)
    }
}
