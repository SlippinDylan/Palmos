import SwiftUI

struct ActionBarView: View {
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack {
            Button("Refresh", action: onRefresh)
            Spacer()
            Button("Quit", action: onQuit)
                .keyboardShortcut("q")
        }
    }
}
