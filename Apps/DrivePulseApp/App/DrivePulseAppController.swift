import AppKit
import SwiftUI

import DrivePulseCore

@MainActor
final class DrivePulseAppController: ObservableObject {
    @Published private(set) var state: DrivePulseAppState

    init(state: DrivePulseAppState = .preview) {
        self.state = state
    }

    func selectDevice(_ id: DeviceID?) {
        state.selectDevice(id)
    }

    func refresh() {
        state.replaceDevices(state.devices)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
