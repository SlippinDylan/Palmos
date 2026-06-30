import SwiftUI

import DrivePulseCore

struct VolumesPartitionsCardView: View {
    let device: ExternalDevice?

    var body: some View {
        PanelSection("Volumes & Partitions") {
            let hasContainer = device?.apfsContainerDetails != nil
            let hasPartitions = device?.physicalPartitions.isEmpty == false
            if hasContainer || hasPartitions {
                VStack(alignment: .leading, spacing: 8) {
                    if let container = device?.apfsContainerDetails {
                        if !container.volumes.isEmpty {
                            ForEach(container.volumes, id: \.bsdName) { volume in
                                volumeBlock(volume)
                            }
                            Divider()
                        }
                        containerBlock(container)
                    }
                    if let partitions = device?.physicalPartitions, !partitions.isEmpty {
                        if device?.apfsContainerDetails != nil {
                            Divider()
                        }
                        partitionsBlock(partitions)
                    }
                }
            } else {
                Text("No volume information available")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func volumeBlock(_ volume: APFSVolumeDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(volume.volumeName)
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("BSD Name", volume.bsdName)
                row("Mount Point", PanelDisplayValue.string(volume.mountPoint))
                row("File System", volume.fileSystem ?? "APFS")
                row("Role", PanelDisplayValue.string(volume.role))
                row("Used", capacityStr(volume.capacityConsumedBytes))
                row("FileVault", boolStr(volume.fileVaultEnabled))
                row("Sealed", boolStr(volume.sealed))
                row("Volume UUID", PanelDisplayValue.string(volume.volumeUUID))
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func containerBlock(_ container: APFSContainerInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("APFS Container")
                .font(.system(size: 12, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Container ID", container.bsdName)
                row("Physical Store", PanelDisplayValue.string(container.physicalStoreBSDName))
                row("Total", capacityStr(container.totalCapacityBytes))
                row("Used", capacityWithPct(container.capacityInUseBytes, of: container.totalCapacityBytes))
                row("Free", capacityWithPct(container.capacityNotAllocatedBytes, of: container.totalCapacityBytes))
                row("Container UUID", PanelDisplayValue.string(container.containerUUID))
                row("Physical Store UUID", PanelDisplayValue.string(container.physicalStoreUUID))
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private func partitionsBlock(_ partitions: [PhysicalPartitionInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Physical Partitions")
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(partitions.enumerated()), id: \.element.bsdName) { index, partition in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(partition.bsdName)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            row("Partition Type", PanelDisplayValue.string(partition.partitionType))
                            row("Name", PanelDisplayValue.string(partition.name))
                            row("Size", capacityStr(partition.sizeBytes))
                        }
                        .font(.system(size: 12))
                    }

                    if index < partitions.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        PanelKeyValueRow(label, value: value, usesMonospacedDigits: true)
    }

    private func capacityStr(_ bytes: Int64?) -> String {
        guard let bytes else { return PanelDisplayValue.missing }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func capacityWithPct(_ bytes: Int64?, of total: Int64?) -> String {
        guard let bytes else { return PanelDisplayValue.missing }
        let base = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        guard let total, total > 0 else { return base }
        let pct = Int((Double(bytes) / Double(total) * 100).rounded())
        return "\(base) (\(pct)%)"
    }

    private func boolStr(_ value: Bool?) -> String {
        guard let value else { return PanelDisplayValue.missing }
        return value ? String(localized: "Yes") : String(localized: "No")
    }
}
