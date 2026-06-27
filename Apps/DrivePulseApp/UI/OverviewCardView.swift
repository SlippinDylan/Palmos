import SwiftUI

import DrivePulseCore

struct OverviewCardView: View {
    let device: ExternalDevice?

    var body: some View {
        GroupBox("Overview") {
            if let device {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Connection", value: device.transportName)
                    LabeledContent("Capacity", value: capacityString(for: device.capacityBytes))
                    LabeledContent("Health", value: healthString(for: device.smartSnapshot))
                    LabeledContent("Temperature", value: temperatureString(for: device.smartSnapshot))
                }
            } else {
                Text("No device selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func capacityString(for capacityBytes: Int64?) -> String {
        guard let capacityBytes else {
            return "Unavailable"
        }

        return ByteCountFormatter.string(fromByteCount: capacityBytes, countStyle: .file)
    }

    private func healthString(for snapshot: SmartSnapshot) -> String {
        switch snapshot {
        case .notRequested:
            return "Not requested"
        case .loading:
            return "Loading"
        case .available(let smartData):
            return smartData.overallHealth ?? "Unavailable"
        case .unsupported, .transportUnsupported:
            return "Unsupported"
        case .helperNotInstalled:
            return "Helper required"
        case .permissionRequired:
            return "Permission required"
        case .deviceUnavailable:
            return "Unavailable"
        case .updateRequired:
            return "Update required"
        case .failed:
            return "Unavailable"
        }
    }

    private func temperatureString(for snapshot: SmartSnapshot) -> String {
        guard case let .available(smartData) = snapshot else {
            return "Unavailable"
        }

        guard let temperature = TemperatureSelection.overviewTemperature(for: smartData) else {
            return "Unavailable"
        }

        return "\(temperature) C"
    }
}
