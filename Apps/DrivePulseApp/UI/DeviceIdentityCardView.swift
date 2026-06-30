import SwiftUI

import DrivePulseCore

struct DeviceIdentityCardView: View {
    let device: ExternalDevice?

    var body: some View {
        PanelSection("Device Identity") {
            VStack(alignment: .leading, spacing: 6) {
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
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }
}
