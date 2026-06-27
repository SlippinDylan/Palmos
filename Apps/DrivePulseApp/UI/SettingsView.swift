import SwiftUI

import DrivePulseCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginController: LaunchAtLoginController

    var body: some View {
        Form {
            Section("General") {
                Picker("Temperature Unit", selection: $settings.temperatureUnit) {
                    Text("Celsius").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.segmented)

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLoginController.isEnabled },
                        set: { launchAtLoginController.setEnabled($0) }
                    )
                )
                .disabled(launchAtLoginController.isUpdating)

                Text("DrivePulse can launch automatically when you sign in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if launchAtLoginController.needsApproval {
                    Text("Approval needed in Login Items Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Open Login Items Settings") {
                        launchAtLoginController.openLoginItemsSettings()
                    }
                }

                if let lastErrorMessage = launchAtLoginController.lastErrorMessage,
                   lastErrorMessage.isEmpty == false {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }
}
