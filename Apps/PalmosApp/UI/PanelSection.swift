import SwiftUI

enum PanelDisplayValue {
    static let missing = "-"

    static func string(_ value: String?) -> String {
        guard let value, value.isEmpty == false else {
            return missing
        }

        return value
    }
}

struct PanelSection<HeaderAccessory: View, Content: View>: View {
    let title: LocalizedStringKey
    let headerAccessory: HeaderAccessory
    let content: Content

    init(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) where HeaderAccessory == EmptyView {
        self.title = title
        self.headerAccessory = EmptyView()
        self.content = content()
    }

    init(
        _ title: LocalizedStringKey,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.headerAccessory = headerAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)

                Spacer(minLength: 0)

                headerAccessory
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct PanelKeyValueRow: View {
    let label: LocalizedStringKey
    let value: String
    let valueColor: Color
    let usesMonospacedDigits: Bool

    init(
        _ label: LocalizedStringKey,
        value: String,
        valueColor: Color = .primary,
        usesMonospacedDigits: Bool = false
    ) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
        self.usesMonospacedDigits = usesMonospacedDigits
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            valueText
                .foregroundStyle(valueColor)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var valueText: some View {
        if usesMonospacedDigits {
            Text(value)
                .monospacedDigit()
        } else {
            Text(value)
        }
    }
}
