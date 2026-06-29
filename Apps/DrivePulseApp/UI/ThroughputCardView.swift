import SwiftUI

import DrivePulseCore

struct ThroughputCardView: View {
    let device: ExternalDevice?

    var body: some View {
        PanelSection("Throughput") {
            if let metrics = device?.sessionMetrics {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Read", value: rateString(metrics.currentReadBytesPerSecond))
                    LabeledContent("Write", value: rateString(metrics.currentWriteBytesPerSecond))
                    LabeledContent("Total Read", value: byteCountString(metrics.cumulativeReadBytes))
                    LabeledContent("Total Write", value: byteCountString(metrics.cumulativeWriteBytes))
                }
            } else {
                Text("No throughput data")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rateString(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(bytesPerSecond.rounded())
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))/s"
    }

    private func byteCountString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
