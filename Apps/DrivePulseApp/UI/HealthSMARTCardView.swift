import SwiftUI

import DrivePulseCore

struct HealthSMARTCardView: View {
    let smartDetails: SMARTPresentationDetails?
    let onInstallHelper: () -> Void
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
                    InfoRow("Overall Health", value: PanelDisplayValue.string(smartData?.overallHealth))
                    InfoRow("Critical Warning", value: criticalWarningString)
                    InfoRow("Wear Level", value: wearLevelString)
                    InfoRow("Available Spare", value: availableSpareString)
                    InfoRow("Media Integrity Errors", value: mediaIntegrityErrorsString)
                    InfoRow("Error Log Entries", value: errorLogEntriesString)
                }

                Divider()
                    .padding(.vertical, 6)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    InfoRow("Power-On Hours", value: powerOnHoursString)
                    InfoRow("Power Cycles", value: powerCyclesString)
                    InfoRow("Unsafe Shutdowns", value: unsafeShutdownsString)
                    InfoRow("Total Written", value: totalWrittenString)
                    InfoRow("Total Read", value: totalReadString)
                    InfoRow("Controller Busy Time", value: controllerBusyTimeString)
                    InfoRow("Warning Temp Time", value: warningTempTimeString)
                    InfoRow("Critical Temp Time", value: criticalTempTimeString)
                }

                if isHelperNotInstalled {
                    Button("Install SMART Helper for Complete Health Data") { onInstallHelper() }
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

    private var isHelperNotInstalled: Bool {
        guard let snapshot = smartDetails?.snapshot else { return false }
        if case .helperNotInstalled = snapshot { return true }
        return false
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

private struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    init(_ label: LocalizedStringKey, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
