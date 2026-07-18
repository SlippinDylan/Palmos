import Foundation

struct ThroughputSample {
    let timestamp: Date
    let readBytes: Int64
    let writeBytes: Int64
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double

    init(readBytes: Int64, writeBytes: Int64, at timestamp: Date, previousTimestamp: Date?) {
        let rates: (read: Double, write: Double)
        if let previousTimestamp {
            let measuredInterval = timestamp.timeIntervalSince(previousTimestamp)
            let interval = measuredInterval > 0 ? measuredInterval : 1
            rates = (Double(readBytes) / interval, Double(writeBytes) / interval)
        } else {
            rates = (0, 0)
        }

        self.timestamp = timestamp
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readBytesPerSecond = rates.read.isFinite ? rates.read : Double.greatestFiniteMagnitude
        self.writeBytesPerSecond = rates.write.isFinite ? rates.write : Double.greatestFiniteMagnitude
    }

    var readPoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: readBytesPerSecond)
    }

    var writePoint: SpeedPoint {
        .init(timestamp: timestamp, bytesPerSecond: writeBytesPerSecond)
    }
}
