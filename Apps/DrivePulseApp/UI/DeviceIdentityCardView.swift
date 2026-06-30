import SwiftUI

import DrivePulseCore

struct DeviceIdentityCardView: View {
    struct Row: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { label }
    }

    let device: ExternalDevice?

    var body: some View {
        PanelSection("Device Identity") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Self.rows(for: device)) { row in
                    PanelKeyValueRow(LocalizedStringKey(row.label), value: row.value)
                }
            }
        }
    }

    static func rows(for device: ExternalDevice?) -> [Row] {
        [
            Row(label: "Physical Disk", value: PanelDisplayValue.string(device?.physicalStoreBSDName)),
            Row(label: "APFS Container", value: PanelDisplayValue.string(device?.apfsContainerBSDName)),
            Row(label: "APFS Volume", value: PanelDisplayValue.string(primaryVolumeBSDName(for: device))),
            Row(label: "Device Node", value: PanelDisplayValue.string(deviceNode(for: device))),
            Row(label: "Volume UUID", value: PanelDisplayValue.string(device?.apfsContainerDetails?.volumes.first?.volumeUUID)),
            Row(label: "Container UUID", value: PanelDisplayValue.string(device?.apfsContainerDetails?.containerUUID)),
            Row(label: "Physical Store UUID", value: PanelDisplayValue.string(device?.apfsContainerDetails?.physicalStoreUUID)),
            Row(label: "NVMe Serial", value: PanelDisplayValue.string(device?.nvmeInfo?.serialNumber)),
            Row(label: "Thunderbolt UID", value: PanelDisplayValue.string(device?.thunderboltInfo?.uid)),
            Row(label: "PCI Vendor ID", value: PanelDisplayValue.string(device?.pciInfo?.vendorID)),
            Row(label: "PCI Device ID", value: PanelDisplayValue.string(device?.pciInfo?.deviceID))
        ]
    }

    private static func primaryVolumeBSDName(for device: ExternalDevice?) -> String? {
        device?.volumes.first?.bsdName ?? device?.apfsContainerDetails?.volumes.first?.bsdName
    }

    private static func deviceNode(for device: ExternalDevice?) -> String? {
        guard let bsdName = device?.physicalStoreBSDName, bsdName.isEmpty == false else {
            return nil
        }

        return "/dev/\(bsdName)"
    }
}
