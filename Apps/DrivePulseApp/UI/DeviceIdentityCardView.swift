import SwiftUI

import DrivePulseCore

struct DeviceIdentityCardView: View {
    let device: ExternalDevice?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Device Identity", isExpanded: $isExpanded) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Physical Disk", device?.physicalStoreBSDName ?? "—")
                row("APFS Container", device?.apfsContainerBSDName ?? "—")
                row("APFS Volume", device?.volumes.first?.bsdName ?? "—")
                row("Device Node", device.map { "/dev/\($0.physicalStoreBSDName)" } ?? "—")
                row("Volume UUID", device?.apfsContainerDetails?.volumes.first?.volumeUUID ?? "—")
                row("Container UUID", device?.apfsContainerDetails?.containerUUID ?? "—")
                row("Physical Store UUID", device?.apfsContainerDetails?.physicalStoreUUID ?? "—")
                row("NVMe Serial", device?.nvmeInfo?.serialNumber ?? "—")
                row("Thunderbolt UID", device?.thunderboltInfo?.uid ?? "—")
                row("PCI Vendor ID", device?.pciInfo?.vendorID ?? "—")
                row("PCI Device ID", device?.pciInfo?.deviceID ?? "—")
            }
            .padding(.top, 6)
        }
        .padding(10)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }
}
