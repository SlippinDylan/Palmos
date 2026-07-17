import SwiftUI

import DrivePulseCore

struct SettingsPane<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(.top, 4)
            .padding(.horizontal, 2)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let systemImage: String
    let control: Control

    init(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title: title, subtitle: subtitle, systemImage: systemImage)
            Spacer(minLength: 16)
            control
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let systemImage: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FixedPanelRow: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowLabel(title: title, subtitle: nil, systemImage: systemImage)
            Spacer()
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Always Shown")
        }
    }
}

struct SettingsNotice<Action: View>: View {
    let message: String
    let color: Color
    let action: Action

    init(
        message: String,
        color: Color,
        @ViewBuilder action: () -> Action = { EmptyView() }
    ) {
        self.message = message
        self.color = color
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(color)
            Text(LocalizedStringKey(message))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            action
        }
    }
}

struct SettingsGroupTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }
}

struct SettingsGlassButton: View {
    let title: LocalizedStringKey
    let prominent: Bool
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        let button = Button(title, action: action)
            .controlSize(.regular)

        if #available(macOS 26.0, *) {
            if prominent {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.glass)
            }
        } else if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

extension PanelDetailSection {
    var title: LocalizedStringKey {
        switch self {
        case .healthSMART: "Health & SMART"
        case .temperature: "Temperature"
        case .volumesPartitions: "Volumes & Partitions"
        case .connectionNVMe: "Connection & NVMe"
        case .deviceIdentity: "Device Identity"
        }
    }

    var systemImage: String {
        switch self {
        case .healthSMART: "heart.text.square"
        case .temperature: "thermometer.medium"
        case .volumesPartitions: "square.stack.3d.up"
        case .connectionNVMe: "cable.connector"
        case .deviceIdentity: "info.square"
        }
    }
}
