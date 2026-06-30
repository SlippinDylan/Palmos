import SwiftUI

import DrivePulseCore

struct MenuBarRootView: View {
    @ObservedObject var controller: DrivePulseAppController

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    DevicePickerView(
                        devices: controller.state.devices,
                        selectedDeviceID: Binding(
                            get: { controller.state.selectedDeviceID },
                            set: { controller.selectDevice($0) }
                        )
                    )
                    OverviewCardView(
                        device: controller.state.selectedDevice,
                        smartDetails: controller.state.selectedSMARTDetails,
                        settings: controller.settings,
                        onInstallHelper: { controller.performSMARTPrimaryAction() }
                    )
                    ThroughputCardView(device: controller.state.selectedDevice)
                    HealthSMARTCardView(
                        smartDetails: controller.state.selectedSMARTDetails,
                        onInstallHelper: { controller.performSMARTPrimaryAction() },
                        onRefresh: { controller.refreshSelectedDeviceSMART() }
                    )
                    TemperatureCardView(
                        smartDetails: controller.state.selectedSMARTDetails,
                        settings: controller.settings
                    )
                    VolumesPartitionsCardView(device: controller.state.selectedDevice)
                    ConnectionNVMeCardView(device: controller.state.selectedDevice)
                    DeviceIdentityCardView(device: controller.state.selectedDevice)
                }
                .padding(14)
            }
            .frame(height: (NSScreen.main?.frame.height ?? 900) * 3 / 5)

            Divider()

            ActionBarView(
                actions: controller.selectedDeviceActions,
                isPerformingAction: controller.isPerformingSystemAction,
                message: controller.actionFeedback,
                onAction: controller.perform
            )
            .padding(14)
        }
        .frame(width: 360)
        .containerBackground(.regularMaterial, for: .window)
        .alert(
            "Install Advanced Monitoring",
            isPresented: installPromptBinding
        ) {
            Button("Install") {
                controller.installSMARTHelper()
            }
            Button("Cancel", role: .cancel) {
                controller.dismissSMARTPrompts()
            }
        } message: {
            Text("DrivePulse needs to install the privileged SMART helper to read drive health data.")
        }
        .alert(
            "Update Advanced Monitoring",
            isPresented: updatePromptBinding
        ) {
            Button("Update") {
                controller.installSMARTHelper()
            }
            Button("Cancel", role: .cancel) {
                controller.dismissSMARTPrompts()
            }
        } message: {
            Text("DrivePulse needs to update the privileged SMART helper before SMART data can be refreshed.")
        }
    }

    private var installPromptBinding: Binding<Bool> {
        Binding(
            get: { controller.state.presentation.showHelperInstallPrompt },
            set: { isPresented in
                if isPresented == false {
                    controller.dismissSMARTPrompts()
                }
            }
        )
    }

    private var updatePromptBinding: Binding<Bool> {
        Binding(
            get: { controller.state.presentation.showHelperUpdatePrompt },
            set: { isPresented in
                if isPresented == false {
                    controller.dismissSMARTPrompts()
                }
            }
        )
    }
}
