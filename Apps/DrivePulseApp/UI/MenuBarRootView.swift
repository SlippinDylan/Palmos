import SwiftUI

import DrivePulseCore

struct MenuBarRootView: View {
    @ObservedObject var controller: DrivePulseAppController

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DevicePickerView(
                        devices: controller.state.devices,
                        selectedDeviceID: Binding(
                            get: { controller.state.selectedDeviceID },
                            set: { controller.selectDevice($0) }
                        )
                    )
                    OverviewCardView(device: controller.state.selectedDevice)
                    ThroughputCardView(device: controller.state.selectedDevice)
                    VolumesSectionView(device: controller.state.selectedDevice)
                    DetailsSectionView(device: controller.state.selectedDevice)
                }
                .padding(14)
            }
            Divider()
            ActionBarView(
                onRefresh: controller.refresh,
                onQuit: controller.quit
            )
            .padding(14)
        }
        .frame(width: 360, alignment: .top)
        .frame(maxHeight: 520, alignment: .top)
    }
}
