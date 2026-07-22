import AppKit
import SwiftUI

import DrivePulseCore

struct CapacityUsageModel: Equatable {
    let totalBytes: Int64?
    let usedBytes: Int64?
    let availableBytes: Int64?

    init(device: ExternalDevice) {
        let container = device.apfsContainerDetails
        let snapshot = Self.snapshot(
            total: container?.totalCapacityBytes,
            used: container?.capacityInUseBytes,
            available: container?.capacityNotAllocatedBytes
        ) ?? device.volumes.lazy.compactMap { volume in
            Self.snapshot(
                total: volume.capacityTotalBytes,
                used: volume.capacityConsumedBytes,
                available: volume.capacityAvailableBytes
            )
        }.first

        totalBytes = snapshot?.total
        usedBytes = snapshot?.used
        availableBytes = snapshot?.available
    }

    var usedFraction: Double {
        segmentFractions.used
    }

    var availableFraction: Double {
        segmentFractions.available
    }

    private var segmentFractions: (used: Double, available: Double) {
        guard let totalBytes else {
            return (0, 0)
        }

        let total = Double(totalBytes)
        let used = Double(usedBytes ?? 0)
        let available = Double(availableBytes ?? 0)
        let denominator = max(total, used + available)
        guard denominator > 0 else {
            return (0, 0)
        }

        return (used / denominator, available / denominator)
    }

    private struct Snapshot {
        let total: Int64
        let used: Int64
        let available: Int64
    }

    private static func snapshot(
        total: Int64?,
        used: Int64?,
        available: Int64?
    ) -> Snapshot? {
        guard let total = positive(total),
              let used = nonnegative(used),
              let available = nonnegative(available) else {
            return nil
        }
        return Snapshot(total: total, used: used, available: available)
    }

    private static func positive(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func nonnegative(_ value: Int64?) -> Int64? {
        guard let value, value >= 0 else { return nil }
        return value
    }
}

struct CapacityUsageCardView: View {
    let model: CapacityUsageModel

    init(device: ExternalDevice) {
        model = CapacityUsageModel(device: device)
    }

    var body: some View {
        PanelSection("Capacity") {
            VStack(alignment: .leading, spacing: 10) {
                CapacitySegmentBar(model: model)

                HStack(alignment: .top, spacing: 16) {
                    CapacityLegendItem(
                        title: "Used",
                        value: formatted(model.usedBytes),
                        color: .accentColor
                    )

                    Spacer(minLength: 0)

                    CapacityLegendItem(
                        title: "Available",
                        value: formatted(model.availableBytes),
                        color: Color(nsColor: .controlBackgroundColor),
                        hasOutline: true
                    )
                }
            }
        }
    }

    private func formatted(_ bytes: Int64?) -> String {
        guard let bytes else { return PanelDisplayValue.missing }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct CapacitySegmentBar: View {
    let model: CapacityUsageModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.primary.opacity(0.03)

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Color(nsColor: .controlBackgroundColor)
                        .frame(width: geometry.size.width * model.availableFraction)
                }

                HStack(spacing: 0) {
                    Color.accentColor
                        .frame(width: geometry.size.width * model.usedFraction)
                    Spacer(minLength: 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

private struct CapacityLegendItem: View {
    let title: LocalizedStringKey
    let value: String
    let color: Color
    var hasOutline = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
                .overlay {
                    if hasOutline {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.24), lineWidth: 1)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }
}
