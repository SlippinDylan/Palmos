import SwiftUI

import DrivePulseCore

struct DetailsSectionView: View {
    let device: ExternalDevice?

    var body: some View {
        GroupBox("Details") {
            if let device {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Physical Disk")
                            .foregroundStyle(.secondary)
                        Text(device.physicalStoreBSDName)
                    }
                    GridRow {
                        Text("APFS Container")
                            .foregroundStyle(.secondary)
                        Text(device.apfsContainerBSDName ?? "Unavailable")
                    }
                    GridRow {
                        Text("Device ID")
                            .foregroundStyle(.secondary)
                        Text(device.id.rawValue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No device details available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
