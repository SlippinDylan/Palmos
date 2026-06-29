import SwiftUI

import DrivePulseCore

struct OverviewCardView: View {
    let device: ExternalDevice?
    @ObservedObject var settings: AppSettings

    var body: some View {
        PanelSection("Overview") {
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
            }
        }
    }

    private func capacityString(for capacityBytes: Int64?) -> String {
        guard let capacityBytes else {
            return "Unavailable"
        }

        return ByteCountFormatter.string(fromByteCount: capacityBytes, countStyle: .file)
    }

    func healthString(for snapshot: SmartSnapshot) -> String {
        switch snapshot {
        case .notRequested:
            return String(localized: "Not requested")
        case .loading:
            return String(localized: "Loading")
        case .available(let smartData):
            guard let overallHealth = smartData.overallHealth else {
                return String(localized: "Unavailable")
            }

            return localizedHealthString(overallHealth)
        case .unsupported:
            return String(localized: "Unsupported")
        case .transportUnsupported:
            return String(localized: "Transport support required")
        case .helperNotInstalled:
            return String(localized: "Helper required")
        case .permissionRequired:
            return String(localized: "Permission required")
        case .deviceUnavailable:
            return String(localized: "Unavailable")
        case .updateRequired:
            return String(localized: "Update required")
        case .failed:
            return String(localized: "Unavailable")
        }
    }

    private func temperatureString(for snapshot: SmartSnapshot) -> String {
        guard case let .available(smartData) = snapshot else {
            return String(localized: "Unavailable")
        }

        guard let temperature = TemperatureSelection.overviewTemperature(for: smartData) else {
            return String(localized: "Unavailable")
        }

        return settings.temperatureUnit.format(temperature)
    }

    private func localizedHealthString(_ overallHealth: String) -> String {
        switch overallHealth {
        case "Verified":
            return String(localized: "Verified")
        default:
            return overallHealth
        }
    }
}
