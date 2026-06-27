import SwiftUI

struct ActionBarView: View {
    let actions: [SystemAction]
    let message: String?
    let onAction: (SystemAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(actions) { action in
                    if action.kind == .settings {
                        SettingsLink {
                            Label(action.title, systemImage: action.systemImageName)
                        }
                    } else {
                        Button {
                            onAction(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImageName)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)

            if let message, message.isEmpty == false {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
