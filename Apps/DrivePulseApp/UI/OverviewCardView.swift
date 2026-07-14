import SwiftUI

import DrivePulseCore

struct OverviewCardView: View {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { label }
    }

    let device: ExternalDevice?
    let smartDetails: SMARTPresentationDetails?
    @ObservedObject var settings: AppSettings

    var body: some View {
        PanelSection("Overview") {
            if let device {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Self.rows(for: device, smartDetails: smartDetails, settings: settings)) { row in
                        PanelKeyValueRow(LocalizedStringKey(row.label), value: row.value)
                    }
                }
            } else {
                Text("No device selected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func rows(
        for device: ExternalDevice,
        smartDetails: SMARTPresentationDetails?,
        settings: AppSettings
    ) -> [Row] {
        let view = OverviewCardView(device: device, smartDetails: smartDetails, settings: settings)

        return [
            Row(label: "Model", value: view.modelString(device)),
            Row(label: "Connection", value: view.connectionString(device)),
            Row(label: "Total Capacity", value: view.totalCapacityString(device)),
            Row(label: "Used", value: view.usedSpaceString(device)),
            Row(label: "Available", value: view.availableSpaceString(device)),
            Row(
                label: "File System",
                value: device.apfsContainerBSDName != nil ? "APFS" : PanelDisplayValue.missing
            ),
            Row(label: "Mounted", value: device.volumes.isEmpty ? "Not Mounted" : "Mounted")
        ]
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
        let mountedVolume = device.volumes.first(where: { $0.capacityConsumedBytes != nil })
        guard
            let total = device.apfsContainerDetails?.totalCapacityBytes
                ?? mountedVolume?.capacityTotalBytes,
            let used = device.apfsContainerDetails?.capacityInUseBytes
                ?? mountedVolume?.capacityConsumedBytes,
            total > 0
        else { return PanelDisplayValue.missing }
        let pct = Double(used) / Double(total) * 100
        let formatted = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        return "\(formatted) (\(String(format: "%.1f", pct))%)"
    }

    private func availableSpaceString(_ device: ExternalDevice) -> String {
        let mountedVolume = device.volumes.first(where: { $0.capacityAvailableBytes != nil })
        guard
            let total = device.apfsContainerDetails?.totalCapacityBytes
                ?? mountedVolume?.capacityTotalBytes,
            let free = device.apfsContainerDetails?.capacityNotAllocatedBytes
                ?? mountedVolume?.capacityAvailableBytes,
            total > 0
        else { return PanelDisplayValue.missing }
        let pct = Double(free) / Double(total) * 100
        let formatted = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        return "\(formatted) (\(String(format: "%.1f", pct))%)"
    }
}
