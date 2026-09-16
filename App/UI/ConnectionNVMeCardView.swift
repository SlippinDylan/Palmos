import SwiftUI

import PalmosCore

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
            row("Device Name", PanelDisplayValue.string(tb.deviceName))
            row("Vendor", PanelDisplayValue.string(tb.vendorName))
            row("Protocol", PanelDisplayValue.string(tb.mode))
            row("Bus", PanelDisplayValue.string(tb.bus.map { PanelValueFormatter.bus(String($0)) }))
            row("Receptacle", PanelDisplayValue.string(tb.receptacle.map { PanelValueFormatter.receptacle(String($0)) }))
            row("Link Speed", PanelDisplayValue.string(tb.linkSpeed))
            row("UID", PanelDisplayValue.string(tb.uid))
            row("Enclosure Firmware", PanelDisplayValue.string(tb.firmwareVersion))
            row("Link Controller Firmware", PanelDisplayValue.string(tb.linkControllerFirmwareVersion))
            row("Upstream Port", PanelDisplayValue.string(tb.upstreamPortStatus))
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var nvmePCIBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NVMe & PCI")
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Controller", PanelDisplayValue.string(device?.nvmeInfo?.controller))
                row("Model", PanelDisplayValue.string(device?.nvmeInfo?.model))
                row("Serial Number", PanelDisplayValue.string(device?.nvmeInfo?.serialNumber))
                row("Firmware", PanelDisplayValue.string(device?.nvmeInfo?.firmwareVersion))
                row("NVMe Version", PanelDisplayValue.string(device?.nvmeInfo?.nvmeVersion))
                row("TRIM", device?.nvmeInfo?.trimSupport.map { PanelValueFormatter.yesNo($0) } ?? PanelDisplayValue.missing)
                row("PCIe Width", PanelDisplayValue.string(device?.nvmeInfo?.linkWidth))
                row("PCIe Speed", PanelDisplayValue.string(device?.nvmeInfo?.linkSpeed))
                row("Firmware Slots", device?.nvmeInfo?.firmwareSlots.map { "\($0)" } ?? PanelDisplayValue.missing)
                row("Firmware No-Reset Update", device?.nvmeInfo?.firmwareUpdateRequiresReset.map { PanelValueFormatter.yesNo(!$0) } ?? PanelDisplayValue.missing)
                row("IEEE OUI", PanelDisplayValue.string(device?.nvmeInfo?.ieeeOui))
                row("PCI Slot", PanelDisplayValue.string(device?.pciInfo?.slot))
                row("PCI Vendor ID", PanelDisplayValue.string(device?.pciInfo?.vendorID))
                row("PCI Device ID", PanelDisplayValue.string(device?.pciInfo?.deviceID))
                row("PCI Link Status", PanelDisplayValue.string(device?.pciInfo?.linkStatus))
                row("Tunnel Compatible", device?.pciInfo?.tunnelCompatible.map { PanelValueFormatter.yesNo($0) } ?? PanelDisplayValue.missing)
                row("PCI Link Width", PanelDisplayValue.string(device?.pciInfo?.linkWidth))
                row("PCI Link Speed", PanelDisplayValue.string(device?.pciInfo?.linkSpeed))
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        PanelKeyValueRow(label, value: value, usesMonospacedDigits: true)
    }
}
