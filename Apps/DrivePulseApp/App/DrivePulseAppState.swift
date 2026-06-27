import Foundation

import DrivePulseCore

struct DrivePulseAppState: Equatable {
    var devices: [ExternalDevice]
    var selectedDeviceID: DeviceID?

    init(devices: [ExternalDevice] = [], selectedDeviceID: DeviceID?) {
        self.devices = devices
        self.selectedDeviceID = Self.resolveSelection(
            devices: devices,
            preferredID: selectedDeviceID
        )
    }

    var selectedDevice: ExternalDevice? {
        guard let selectedDeviceID else {
            return devices.first
        }

        return devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first
    }

    mutating func selectDevice(_ id: DeviceID?) {
        selectedDeviceID = Self.resolveSelection(devices: devices, preferredID: id)
    }

    mutating func replaceDevices(_ devices: [ExternalDevice]) {
        self.devices = devices
        selectedDeviceID = Self.resolveSelection(
            devices: devices,
            preferredID: selectedDeviceID
        )
    }

    static var preview: Self {
        .init(
            devices: [
                .preview(id: "disk4"),
                .preview(id: "disk8")
            ],
            selectedDeviceID: nil
        )
    }

    private static func resolveSelection(
        devices: [ExternalDevice],
        preferredID: DeviceID?
    ) -> DeviceID? {
        guard let preferredID else {
            return devices.first?.id
        }

        return devices.contains(where: { $0.id == preferredID })
            ? preferredID
            : devices.first?.id
    }
}
