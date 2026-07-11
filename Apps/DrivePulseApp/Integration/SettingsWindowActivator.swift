import AppKit
import Combine
import SwiftUI

/// Bridges SwiftUI's `openSettings()` environment action into an `LSUIElement`
/// (accessory, no Dock icon) menu-bar-only app.
///
/// `openSettings()` only reliably activates and raises the Settings window when
/// it is called from a view that belongs to an already-focusable window scene.
/// `MenuBarExtra`'s `.window` content is a transient auxiliary panel, not a
/// normal window, so calling `openSettings()` directly from inside it (as
/// SwiftUI's own `SettingsLink` docs assume) leaves the app in `.accessory`
/// activation policy and the new Settings window never gets properly ordered
/// front — the request is queued and only surfaces after a long, inconsistent
/// delay. The fix (FB10184971) is to host the call from a dedicated hidden
/// `Window` scene, and to temporarily promote the app to `.regular` activation
/// policy for the lifetime of the Settings window so macOS treats it like an
/// ordinary focusable window.
@MainActor
final class SettingsWindowActivator: ObservableObject {
    static let hiddenHostWindowID = "settings-activation-bridge"

    /// How long to wait for the Settings window to materialize before giving
    /// up and reverting the activation policy, so a dropped request or a
    /// failed scene never strands the app promoted to `.regular` forever.
    private static let pollInterval: Duration = .milliseconds(100)
    private static let maxPollAttempts = 15 // ~1.5s at pollInterval

    fileprivate let openRequests = PassthroughSubject<Void, Never>()
    private var openTask: Task<Void, Never>?

    /// The Settings window, once identified. SwiftUI reuses the same window
    /// on subsequent `openSettings()` calls rather than creating a new one,
    /// so later opens can just re-raise this instead of re-running discovery.
    private weak var knownSettingsWindow: NSWindow?

    func open() {
        NSApp.setActivationPolicy(.regular)

        if let window = knownSettingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            raise(window)
            return
        }

        let precedingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))

        openTask?.cancel()
        openTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard Task.isCancelled == false, let self else { return }

            NSApp.activate(ignoringOtherApps: true)
            self.openRequests.send()

            for _ in 0..<Self.maxPollAttempts {
                if let window = self.newlyOpenedWindow(excluding: precedingWindows) {
                    self.knownSettingsWindow = window
                    self.raise(window)
                    return
                }

                try? await Task.sleep(for: Self.pollInterval)
                guard Task.isCancelled == false else { return }
            }

            // The Settings scene never materialized (dropped request, scene
            // failure, etc.) — don't strand the app promoted to `.regular`.
            self.settingsWindowDidClose()
        }
    }

    func settingsWindowDidClose() {
        openTask?.cancel()
        knownSettingsWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func raise(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func newlyOpenedWindow(excluding precedingWindows: Set<ObjectIdentifier>) -> NSWindow? {
        NSApp.windows.first { window in
            window.isVisible
                && window.identifier?.rawValue != Self.hiddenHostWindowID
                && precedingWindows.contains(ObjectIdentifier(window)) == false
        }
    }
}

/// Invisible content for the hidden `Window` scene that owns the
/// `openSettings()` environment action on behalf of the menu bar panel.
struct SettingsWindowHostView: View {
    @ObservedObject var activator: SettingsWindowActivator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(activator.openRequests) {
                openSettings()
            }
            .onAppear(perform: hideFromWindowServer)
    }

    private func hideFromWindowServer() {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == SettingsWindowActivator.hiddenHostWindowID
        }) else {
            return
        }

        window.collectionBehavior = [.auxiliary, .ignoresCycle, .transient]
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
    }
}
