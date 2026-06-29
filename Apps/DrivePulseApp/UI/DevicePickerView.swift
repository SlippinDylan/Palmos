import SwiftUI

import DrivePulseCore

struct DevicePickerView: View {
    let devices: [ExternalDevice]
    @Binding var selectedDeviceID: DeviceID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device")
                .font(.headline)

            // NSPopUpButton ignores frame(maxWidth: .infinity); read the
            // available width explicitly and pin the button to it.
            GeometryReader { proxy in
                Picker("Device", selection: $selectedDeviceID) {
                    ForEach(devices) { device in
                        Text(device.displayName).tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: proxy.size.width)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
