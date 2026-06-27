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
        self.readBytesPerSecond = Double(readBytes) / interval
        self.writeBytesPerSecond = Double(writeBytes) / interval
    }

    var readPoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: readBytesPerSecond)
    }

    var writePoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: writeBytesPerSecond)
    }
}
