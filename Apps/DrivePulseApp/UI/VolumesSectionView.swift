import SwiftUI

import DrivePulseCore

struct VolumesSectionView: View {
    let device: ExternalDevice?

    var body: some View {
        GroupBox("Volumes") {
            if let device, device.volumes.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(device.volumes) { volume in
                        Text(volume.bsdName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("No mounted volumes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
