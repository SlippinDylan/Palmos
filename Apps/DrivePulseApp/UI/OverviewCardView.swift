import SwiftUI

import DrivePulseCore

struct OverviewCardView: View {
    let device: ExternalDevice?
    let smartDetails: SMARTPresentationDetails?
    @ObservedObject var settings: AppSettings
    let onInstallHelper: () -> Void

    var body: some View {
        PanelSection("Overview") {
            if let device {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    InfoRow("Model", value: modelString(device))
                    InfoRow("Connection", value: connectionString(device))
                    InfoRow("Total Capacity", value: totalCapacityString(device))
                    InfoRow("Used", value: usedSpaceString(device))
                    InfoRow("Available", value: availableSpaceString(device))
                    InfoRow("File System", value: device.apfsContainerDetails != nil ? "APFS" : "—")
                    InfoRow("SMART Status", value: smartStatusString)
                    InfoRow("Wear Level", value: wearLevelString)
                    InfoRow("Temperature", value: overviewTemperatureString)
                    InfoRow("Mounted", value: device.volumes.isEmpty ? "Not Mounted" : "Mounted")
                }
                if isHelperNotInstalled {
                    Button("Install SMART Helper for Complete Health Data") { onInstallHelper() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.top, 4)
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

    private var isHelperNotInstalled: Bool {
        guard let snapshot = smartDetails?.snapshot else { return false }
        if case .helperNotInstalled = snapshot { return true }
        return false
    }

    private var smartStatusString: String {
        guard let snapshot = smartDetails?.snapshot else { return "—" }
        if case .available(let data) = snapshot { return data.overallHealth ?? "—" }
        return "—"
    }

    private var wearLevelString: String {
        guard let pct = smartData?.percentageUsed else { return "—" }
        return "\(pct)%"
    }

    private var overviewTemperatureString: String {
        guard let temp = smartData?.primaryTemperature else { return "—" }
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
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func usedSpaceString(_ device: ExternalDevice) -> String {
        guard
            let total = device.apfsContainerDetails?.totalCapacityBytes,
            let used = device.apfsContainerDetails?.capacityInUseBytes,
            total > 0
        else { return "—" }
        let pct = Double(used) / Double(total) * 100
        let formatted = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        return "\(formatted) (\(String(format: "%.1f", pct))%)"
    }

    private func availableSpaceString(_ device: ExternalDevice) -> String {
        guard
            let total = device.apfsContainerDetails?.totalCapacityBytes,
            let free = device.apfsContainerDetails?.capacityNotAllocatedBytes,
            total > 0
        else { return "—" }
        let pct = Double(free) / Double(total) * 100
        let formatted = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        return "\(formatted) (\(String(format: "%.1f", pct))%)"
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
