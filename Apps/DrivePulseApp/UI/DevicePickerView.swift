import SwiftUI

import DrivePulseCore

struct DevicePickerView: View {
    let devices: [ExternalDevice]
    @Binding var selectedDeviceID: DeviceID?

    var body: some View {
        PanelSection("Device") {
            Picker("Device", selection: $selectedDeviceID) {
                ForEach(devices) { device in
                    Text(device.displayName).tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
        }
    }
}
