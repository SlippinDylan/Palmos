import SwiftUI

import PalmosCore

struct VolumesSectionView: View {
    let device: ExternalDevice?

    var body: some View {
        PanelSection("Volumes") {
            if let device, device.volumes.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(device.volumes) { volume in
                        Text(volume.bsdName)
                    }
                }
            } else {
                Text("No mounted volumes")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
