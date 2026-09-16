import SwiftUI

import PalmosCore

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
            Row(
                label: "File System",
                value: device.apfsContainerBSDName != nil ? "APFS" : PanelDisplayValue.missing
            )
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
}
