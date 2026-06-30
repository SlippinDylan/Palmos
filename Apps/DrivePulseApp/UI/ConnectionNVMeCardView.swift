import SwiftUI

import DrivePulseCore

struct ConnectionNVMeCardView: View {
    let device: ExternalDevice?

    var body: some View {
        PanelSection("Connection & NVMe") {
            let hasTB = device?.thunderboltInfo != nil
            let hasNVMePCI = device?.nvmeInfo != nil || device?.pciInfo != nil
            if !hasTB && !hasNVMePCI {
                Text("No connection details available")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let tb = device?.thunderboltInfo {
                        thunderboltBlock(tb)
                    }
                    if device?.nvmeInfo != nil || device?.pciInfo != nil {
                        if device?.thunderboltInfo != nil {
                            Divider()
                        }
                        nvmePCIBlock
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func thunderboltBlock(_ tb: ThunderboltInfo) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Device Name", tb.deviceName ?? "—")
            row("Vendor", tb.vendorName ?? "—")
            row("Protocol", tb.mode ?? "—")
            row("Bus", tb.bus.map { "Bus \($0)" } ?? "—")
            row("Receptacle", tb.receptacle.map { "Receptacle \($0)" } ?? "—")
            row("Link Speed", tb.linkSpeed ?? "—")
            row("UID", tb.uid ?? "—")
            row("Enclosure Firmware", tb.firmwareVersion ?? "—")
            row("Link Controller Firmware", tb.linkControllerFirmwareVersion ?? "—")
            row("Upstream Port", tb.upstreamPortStatus ?? "—")
        }
    }

    @ViewBuilder
    private var nvmePCIBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NVMe & PCI")
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Controller", device?.nvmeInfo?.controller ?? "—")
                row("Model", device?.nvmeInfo?.model ?? "—")
                row("Serial Number", device?.nvmeInfo?.serialNumber ?? "—")
                row("Firmware", device?.nvmeInfo?.firmwareVersion ?? "—")
                row("NVMe Version", device?.nvmeInfo?.nvmeVersion ?? "—")
                row("TRIM", device?.nvmeInfo?.trimSupport.map { $0 ? "Yes" : "No" } ?? "—")
                row("PCIe Width", device?.nvmeInfo?.linkWidth ?? "—")
                row("PCIe Speed", device?.nvmeInfo?.linkSpeed ?? "—")
                row("Firmware Slots", device?.nvmeInfo?.firmwareSlots.map { "\($0)" } ?? "—")
                row("Firmware No-Reset Update", device?.nvmeInfo?.firmwareUpdateRequiresReset.map { $0 ? "No" : "Yes" } ?? "—")
                row("IEEE OUI", device?.nvmeInfo?.ieeeOui ?? "—")
                row("PCI Slot", device?.pciInfo?.slot ?? "—")
                row("PCI Vendor ID", device?.pciInfo?.vendorID ?? "—")
                row("PCI Device ID", device?.pciInfo?.deviceID ?? "—")
                row("PCI Link Status", device?.pciInfo?.linkStatus ?? "—")
                row("Tunnel Compatible", device?.pciInfo?.tunnelCompatible.map { $0 ? "Yes" : "No" } ?? "—")
                row("PCI Link Width", device?.pciInfo?.linkWidth ?? "—")
                row("PCI Link Speed", device?.pciInfo?.linkSpeed ?? "—")
            }
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .monospacedDigit()
        }
    }
}
