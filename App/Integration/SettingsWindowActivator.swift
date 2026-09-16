import AppKit
import Combine
import SwiftUI

@MainActor
protocol SettingsWindowRepresenting: AnyObject {
    var windowIdentifier: String? { get set }
    var isVisible: Bool { get }

    func makeKeyAndOrderFront()
}

extension NSWindow: SettingsWindowRepresenting {
    var windowIdentifier: String? {
        get { identifier?.rawValue }
        set {
            identifier = newValue.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
        }
    }

    func makeKeyAndOrderFront() {
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

@MainActor
protocol SettingsApplicationProviding: AnyObject {
    var windows: [any SettingsWindowRepresenting] { get }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy)
    func activate()
}

@MainActor
private final class LiveSettingsApplication: SettingsApplicationProviding {
    var windows: [any SettingsWindowRepresenting] {
        NSApp.windows.map { $0 }
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

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
    static let settingsWindowID = "palmos-settings-window"

    /// How long to wait for the Settings window to materialize before giving
    /// up and reverting the activation policy, so a dropped request or a
    /// failed scene never strands the app promoted to `.regular` forever.
    let openRequests = PassthroughSubject<Void, Never>()
    private let application: any SettingsApplicationProviding
    private let initialDelay: Duration
    private let pollInterval: Duration
    private let maxPollAttempts: Int
    private let waitOperation: @MainActor (Duration) async -> Bool
    private var openTask: Task<Void, Never>?
    private var openGeneration = 0

    /// The Settings window, once identified. SwiftUI reuses the same window
    /// on subsequent `openSettings()` calls rather than creating a new one,
    /// so later opens can just re-raise this instead of re-running discovery.
    private weak var knownSettingsWindow: (any SettingsWindowRepresenting)?

    init(
        application: any SettingsApplicationProviding = LiveSettingsApplication(),
        initialDelay: Duration = .milliseconds(50),
        pollInterval: Duration = .milliseconds(100),
        maxPollAttempts: Int = 15,
        wait: @escaping @MainActor (Duration) async -> Bool = SettingsWindowActivator.wait
    ) {
        self.application = application
        self.initialDelay = initialDelay
        self.pollInterval = pollInterval
        self.maxPollAttempts = maxPollAttempts
        self.waitOperation = wait
    }

    func open() {
        openTask?.cancel()
        openGeneration += 1
        let generation = openGeneration
        application.setActivationPolicy(.regular)

        if let window = knownSettingsWindow {
            application.activate()
            raise(window)
            return
        }

        let precedingWindows = windowVisibilitySnapshot()

        openTask = Task { @MainActor [weak self] in
            guard let self, await self.waitOperation(self.initialDelay) else { return }
            guard self.isCurrent(generation) else { return }

            self.application.activate()
            self.openRequests.send()

            for _ in 0..<self.maxPollAttempts {
                if let window = self.settingsWindow(after: precedingWindows) {
                    self.registerSettingsWindow(window)
                    self.raise(window)
                    return
                }

                guard await self.waitOperation(self.pollInterval) else { return }
                guard self.isCurrent(generation) else { return }
            }

            // The Settings scene never materialized (dropped request, scene
            // failure, etc.) — don't strand the app promoted to `.regular`.
            self.restoreAccessoryPolicy(for: generation)
        }
    }

    func registerSettingsWindow(_ window: any SettingsWindowRepresenting) {
        window.windowIdentifier = Self.settingsWindowID
        knownSettingsWindow = window
    }

    func settingsWindowDidClose(_ window: any SettingsWindowRepresenting) {
        if let knownSettingsWindow,
           ObjectIdentifier(knownSettingsWindow) != ObjectIdentifier(window) {
            return
        }

        openTask?.cancel()
        openGeneration += 1
        application.setActivationPolicy(.accessory)
    }

    private func raise(_ window: any SettingsWindowRepresenting) {
        window.makeKeyAndOrderFront()
    }

    private func windowVisibilitySnapshot() -> [ObjectIdentifier: Bool] {
        Dictionary(uniqueKeysWithValues: application.windows.map {
            (ObjectIdentifier($0), $0.isVisible)
        })
    }

    private func settingsWindow(
        after precedingWindows: [ObjectIdentifier: Bool]
    ) -> (any SettingsWindowRepresenting)? {
        if let identifiedWindow = application.windows.first(where: {
            $0.windowIdentifier == Self.settingsWindowID
        }) {
            return identifiedWindow
        }

        return application.windows.first { window in
            guard window.windowIdentifier != Self.hiddenHostWindowID,
                  window.isVisible else {
                return false
            }

            return precedingWindows[ObjectIdentifier(window)] != true
        }
    }

    private static func wait(for duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return Task.isCancelled == false
        } catch {
            return false
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        Task.isCancelled == false && generation == openGeneration
    }

    private func restoreAccessoryPolicy(for generation: Int) {
        guard isCurrent(generation) else { return }
        application.setActivationPolicy(.accessory)
    }
}

/// Registers the concrete SwiftUI Settings window and observes its real close
/// event. View disappearance is not equivalent to an `NSWindow` closing.
struct SettingsWindowAccessor: NSViewRepresentable {
    let activator: SettingsWindowActivator

    func makeNSView(context: Context) -> SettingsWindowObservationView {
        SettingsWindowObservationView(activator: activator)
    }

    func updateNSView(_ nsView: SettingsWindowObservationView, context: Context) {
        nsView.activator = activator
        nsView.registerCurrentWindow()
    }
}

@MainActor
final class SettingsWindowObservationView: NSView {
    weak var activator: SettingsWindowActivator?

    init(activator: SettingsWindowActivator) {
        self.activator = activator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerCurrentWindow()
    }

    func registerCurrentWindow() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: nil
        )
        guard let window else { return }

        activator?.registerSettingsWindow(window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc
    private func settingsWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        activator?.settingsWindowDidClose(window)
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
