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

struct PanelSection<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

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
                .multilineTextAlignment(.trailing)
        }
    }
}
