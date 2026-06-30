import AppKit
import SwiftUI

import DrivePulseCore

struct DevicePickerView: View {
    let devices: [ExternalDevice]
    @Binding var selectedDeviceID: DeviceID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            StretchingPopUpButton(
                items: devices.map { .init(id: $0.id, title: $0.displayName) },
                selectedID: $selectedDeviceID
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// NSPopUpButton ignores SwiftUI frame(maxWidth: .infinity).
// Wrapping it via NSViewRepresentable with .defaultLow hugging priority
// lets SwiftUI expand the underlying NSView to the proposed width.
private struct StretchingPopUpButton: NSViewRepresentable {
    struct Item {
        let id: DeviceID
        let title: String
    }

    let items: [Item]
    @Binding var selectedID: DeviceID?

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.removeAllItems()
        var selectedIndex = 0
        for (index, item) in items.enumerated() {
            button.addItem(withTitle: item.title)
            if item.id == selectedID {
                selectedIndex = index
            }
        }
        if items.isEmpty == false {
            button.selectItem(at: selectedIndex)
        }
        context.coordinator.items = items
        context.coordinator.binding = $selectedID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, binding: $selectedID)
    }

    final class Coordinator: NSObject {
        var items: [Item]
        var binding: Binding<DeviceID?>

        init(items: [Item], binding: Binding<DeviceID?>) {
            self.items = items
            self.binding = binding
        }

        @MainActor
        @objc func selectionChanged(_ button: NSPopUpButton) {
            let index = button.indexOfSelectedItem
            guard index >= 0, index < items.count else { return }
            binding.wrappedValue = items[index].id
        }
    }
}
