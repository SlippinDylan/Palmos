import SwiftUI

import DrivePulseCore

struct DevicePickerView: View {
    let devices: [ExternalDevice]
    @Binding var selectedDeviceID: DeviceID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device")
                .font(.headline)

            Picker("Device", selection: $selectedDeviceID) {
                ForEach(devices) { device in
                    Text(device.displayName).tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
