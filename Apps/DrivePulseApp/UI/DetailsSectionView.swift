import SwiftUI

import DrivePulseCore

struct DetailsSectionView: View {
    let device: ExternalDevice?
    let smartDetails: SMARTPresentationDetails?
    @ObservedObject var settings: AppSettings
    let onSMARTAction: (SMARTPresentationPrimaryAction) -> Void

    var body: some View {
        PanelSection("Details") {
            VStack(alignment: .leading, spacing: 12) {
                if let device {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("Physical Disk")
                                .foregroundStyle(.secondary)
                            Text(device.physicalStoreBSDName)
                        }
                        GridRow {
                            Text("APFS Container")
                                .foregroundStyle(.secondary)
                            Text(device.apfsContainerBSDName ?? "Unavailable")
                        }
                        GridRow {
                            Text("Device ID")
                                .foregroundStyle(.secondary)
                            Text(device.id.rawValue)
                        }
                    }
                } else {
                    Text("No device details available")
                        .foregroundStyle(.secondary)
                }

                Divider()

                smartSection
            }
        }
    }

    @ViewBuilder
    private var smartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SMART")
                .font(.headline)

            if let smartDetails {
                Text(title(for: smartDetails))
                    .fontWeight(.medium)
                Text(description(for: smartDetails))
                    .foregroundStyle(.secondary)

                if let lastError = smartDetails.lastError, lastError.isEmpty == false {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 10) {
                    if smartDetails.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button(actionTitle(for: smartDetails)) {
                        onSMARTAction(smartDetails.primaryAction)
                    }
                    .disabled(smartDetails.isRefreshing)
                }
            } else {
                Text("No SMART details available")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func title(for details: SMARTPresentationDetails) -> String {
        if details.isInstalling {
            return "Installing SMART helper"
        }

        if details.isRefreshing, details.snapshot == .loading {
            return "Refreshing SMART data"
        }

        switch details.snapshot {
        case .notRequested:
            return "SMART data not requested"
        case .loading:
            return "Refreshing SMART data"
        case let .available(smartData):
            return smartData.overallHealth ?? "SMART data available"
        case .unsupported:
            return "SMART unavailable for this device"
        case .transportUnsupported:
            return "Additional transport support required"
        case .helperNotInstalled:
            return "SMART helper required"
        case .permissionRequired:
            return "SMART permission required"
        case .deviceUnavailable:
            return "SMART device unavailable"
        case .updateRequired:
            return "SMART helper update required"
        case .failed:
            return "SMART refresh failed"
        }
    }

    func description(for details: SMARTPresentationDetails) -> String {
        if details.isInstalling {
            return "DrivePulse is installing or updating the privileged SMART helper."
        }

        switch details.snapshot {
        case .notRequested:
            return "Refresh SMART data for the selected device."
        case .loading:
            return "DrivePulse is reading SMART data from the helper."
        case let .available(smartData):
            if let temperature = TemperatureSelection.overviewTemperature(for: smartData) {
                return "Highest Temperature: \(settings.temperatureUnit.format(temperature))"
            }
            return "SMART telemetry is available for this device."
        case .unsupported:
            return "This transport or device does not expose SMART telemetry."
        case .transportUnsupported:
            return "This enclosure path needs additional transport support."
        case .helperNotInstalled:
            return "Install the privileged SMART helper to read drive health data."
        case .permissionRequired:
            return "The SMART helper needs permission to access this device."
        case .deviceUnavailable:
            return "The helper could not match the selected device to a SMART-capable disk."
        case .updateRequired:
            return "Update the privileged SMART helper to match the current app contract."
        case let .failed(message):
            return message
        }
    }

    private func actionTitle(for details: SMARTPresentationDetails) -> String {
        if details.isInstalling {
            return "Installing..."
        }

        if details.isRefreshing {
            return "Refreshing..."
        }

        switch details.primaryAction {
        case .installHelper:
            return "Install Helper"
        case .updateHelper:
            return "Update Helper"
        case .refresh:
            return "Refresh SMART"
        }
    }
}
