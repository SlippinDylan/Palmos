import SwiftUI

import DrivePulseCore

struct OverviewCardView: View {
    let device: ExternalDevice?
    let smartDetails: SMARTPresentationDetails?
    @ObservedObject var settings: AppSettings

    var body: some View {
        PanelSection("Overview") {
            if let device {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    PanelKeyValueRow("Model", value: modelString(device))
                    PanelKeyValueRow("Connection", value: connectionString(device))
                    PanelKeyValueRow("Total Capacity", value: totalCapacityString(device))
                    PanelKeyValueRow("Used", value: usedSpaceString(device))
                    PanelKeyValueRow("Available", value: availableSpaceString(device))
                    PanelKeyValueRow(
                        "File System",
                        value: device.apfsContainerBSDName != nil ? "APFS" : PanelDisplayValue.missing
                    )
                    PanelKeyValueRow("SMART Status", value: smartStatusString)
                    PanelKeyValueRow("Wear Level", value: wearLevelString)
                    PanelKeyValueRow("Temperature", value: overviewTemperatureString)
                    PanelKeyValueRow("Mounted", value: device.volumes.isEmpty ? "Not Mounted" : "Mounted")
                }
            } else {
                Text("No device selected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var smartData: SmartData? {
        guard case .available(let data) = smartDetails?.snapshot else { return nil }
        return data
    }

    private var smartStatusString: String {
        guard let snapshot = smartDetails?.snapshot else { return PanelDisplayValue.missing }
        if case .available(let data) = snapshot { return PanelDisplayValue.string(data.overallHealth) }
        return PanelDisplayValue.missing
    }

    private var wearLevelString: String {
        guard let pct = smartData?.percentageUsed else { return PanelDisplayValue.missing }
        return "\(pct)%"
    }

    private var overviewTemperatureString: String {
        guard let temp = smartData?.primaryTemperature else { return PanelDisplayValue.missing }
        return settings.temperatureUnit.format(temp)
    }

    private func modelString(_ device: ExternalDevice) -> String {
        device.nvmeInfo?.model ?? device.displayName
    }

    private func connectionString(_ device: ExternalDevice) -> String {
        var parts = [device.transportName]
        if let linkWidth = device.nvmeInfo?.linkWidth {
            parts.append("PCIe \(linkWidth)")
        }
        return parts.joined(separator: " / ")
    }

    private func totalCapacityString(_ device: ExternalDevice) -> String {
        let bytes = device.apfsContainerDetails?.totalCapacityBytes ?? device.capacityBytes
        guard let bytes else { return PanelDisplayValue.missing }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func usedSpaceString(_ device: ExternalDevice) -> String {
        guard
            let total = device.apfsContainerDetails?.totalCapacityBytes,
            let used = device.apfsContainerDetails?.capacityInUseBytes,
            total > 0
        else { return PanelDisplayValue.missing }
        let pct = Double(used) / Double(total) * 100
        let formatted = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        return "\(formatted) (\(String(format: "%.1f", pct))%)"
    }

    private func availableSpaceString(_ device: ExternalDevice) -> String {
        guard
            let total = device.apfsContainerDetails?.totalCapacityBytes,
            let free = device.apfsContainerDetails?.capacityNotAllocatedBytes,
            total > 0
        else { return PanelDisplayValue.missing }
        let pct = Double(free) / Double(total) * 100
        let formatted = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        return "\(formatted) (\(String(format: "%.1f", pct))%)"
    }
}
