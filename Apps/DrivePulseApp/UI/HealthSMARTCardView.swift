import SwiftUI

import DrivePulseCore

struct HealthSMARTCardView: View {
    let helperPrompt: SMARTHelperPrompt?
    let smartDetails: SMARTPresentationDetails?
    let onInstallHelper: () -> Void
    let onConfirmHelperInstall: () -> Void
    let onDismissHelperPrompt: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        PanelSection("Health & SMART") {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 6)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    PanelKeyValueRow("Overall Health", value: PanelDisplayValue.string(smartData?.overallHealth))
                    PanelKeyValueRow("Critical Warning", value: criticalWarningString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Wear Level", value: wearLevelString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Available Spare", value: availableSpareString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Media Integrity Errors", value: mediaIntegrityErrorsString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Error Log Entries", value: errorLogEntriesString, usesMonospacedDigits: true)
                }

                Divider()
                    .padding(.vertical, 6)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    PanelKeyValueRow("Power-On Hours", value: powerOnHoursString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Power Cycles", value: powerCyclesString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Unsafe Shutdowns", value: unsafeShutdownsString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Total Written", value: totalWrittenString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Total Read", value: totalReadString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Controller Busy Time", value: controllerBusyTimeString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Warning Temp Time", value: warningTempTimeString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Critical Temp Time", value: criticalTempTimeString, usesMonospacedDigits: true)
                }

                if requiresHelperInstallOrUpdate {
                    Button(helperButtonTitle) { onInstallHelper() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                } else if !isLoading {
                    Button("Refresh SMART Data") { onRefresh() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .padding(.top, 8)
                }

                if let helperPrompt {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(helperPrompt.title)
                            .font(.subheadline.weight(.semibold))

                        Text(helperPrompt.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button(helperPrompt.confirmTitle) {
                                onConfirmHelperInstall()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Cancel", role: .cancel) {
                                onDismissHelperPrompt()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 10)
                }
            }
        }
    }

    private var smartData: SmartData? {
        guard case .available(let data) = smartDetails?.snapshot else { return nil }
        return data
    }

    private var isLoading: Bool {
        guard let snapshot = smartDetails?.snapshot else { return false }
        if case .loading = snapshot { return true }
        return false
    }

    private var requiresHelperInstallOrUpdate: Bool {
        guard let snapshot = smartDetails?.snapshot else { return false }
        if case .helperNotInstalled = snapshot { return true }
        if case .updateRequired = snapshot { return true }
        return false
    }

    private var helperButtonTitle: LocalizedStringKey {
        guard let snapshot = smartDetails?.snapshot else {
            return "Install SMART Helper for Complete Health Data"
        }

        switch snapshot {
        case .updateRequired:
            return "Update SMART Helper for Complete Health Data"
        default:
            return "Install SMART Helper for Complete Health Data"
        }
    }

    private var criticalWarningString: String {
        guard let cw = smartData?.criticalWarning else { return PanelDisplayValue.missing }
        let hex = String(format: "0x%02X", cw)
        return cw == 0 ? "\(hex) (No warnings)" : hex
    }

    private var wearLevelString: String {
        guard let pct = smartData?.percentageUsed else { return PanelDisplayValue.missing }
        return "\(pct)%"
    }

    private var availableSpareString: String {
        guard let spare = smartData?.availableSpare else { return PanelDisplayValue.missing }
        guard let threshold = smartData?.availableSpareThreshold else { return "\(spare)%" }
        return "\(spare)% (threshold \(threshold)%)"
    }

    private var mediaIntegrityErrorsString: String {
        guard let value = smartData?.mediaIntegrityErrors else { return PanelDisplayValue.missing }
        return "\(value)"
    }

    private var errorLogEntriesString: String {
        guard let value = smartData?.errorLogEntries else { return PanelDisplayValue.missing }
        return "\(value)"
    }

    private var powerOnHoursString: String {
        guard let value = smartData?.powerOnHours else { return PanelDisplayValue.missing }
        return "\(value) hr"
    }

    private var powerCyclesString: String {
        guard let value = smartData?.powerCycles else { return PanelDisplayValue.missing }
        return "\(value)"
    }

    private var unsafeShutdownsString: String {
        guard let us = smartData?.unsafeShutdowns else { return PanelDisplayValue.missing }
        var text = "\(us)"
        if let pc = smartData?.powerCycles, pc > 0, Double(us) / Double(pc) > 0.15 {
            text += " ⚠️"
        }
        return text
    }

    private var totalWrittenString: String {
        guard let units = smartData?.dataUnitsWritten else { return PanelDisplayValue.missing }
        let bytes = Int64(units) * 512_000
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var totalReadString: String {
        guard let units = smartData?.dataUnitsRead else { return PanelDisplayValue.missing }
        let bytes = Int64(units) * 512_000
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var controllerBusyTimeString: String {
        guard let value = smartData?.controllerBusyTime else { return PanelDisplayValue.missing }
        return "\(value) min"
    }

    private var warningTempTimeString: String {
        guard let value = smartData?.warningTempTime else { return PanelDisplayValue.missing }
        return "\(value) min"
    }

    private var criticalTempTimeString: String {
        guard let value = smartData?.criticalTempTime else { return PanelDisplayValue.missing }
        return "\(value) min"
    }
}

enum SMARTHelperPrompt: Equatable {
    case install
    case update

    var title: LocalizedStringKey {
        switch self {
        case .install:
            return "Install Advanced Monitoring"
        case .update:
            return "Update Advanced Monitoring"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .install:
            return "DrivePulse needs to install the privileged SMART helper to read drive health data."
        case .update:
            return "DrivePulse needs to update the privileged SMART helper before SMART data can be refreshed."
        }
    }

    var confirmTitle: LocalizedStringKey {
        switch self {
        case .install:
            return "Install"
        case .update:
            return "Update"
        }
    }
}
