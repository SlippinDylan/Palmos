import AppKit
import SwiftUI

import PalmosCore

@MainActor
protocol SettingsApplicationProviding: AnyObject {
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy)
    func activate()
}

@MainActor
private final class LiveSettingsApplication: SettingsApplicationProviding {
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }

    func activate() {
        NSApp.activate()
    }
}

@MainActor
protocol SettingsWindowPresenting: AnyObject {
    var onClose: (() -> Void)? { get set }
    func present()
}

/// Owns the AppKit settings window used by the menu-bar-only application.
/// AppKit controls the preference toolbar and window chrome; SwiftUI only
/// renders the selected pane's content.
@MainActor
final class SettingsWindowActivator: ObservableObject {
    private let application: any SettingsApplicationProviding
    private let makeWindowController: @MainActor () -> any SettingsWindowPresenting
    private var windowController: (any SettingsWindowPresenting)?

    init(
        settings: AppSettings,
        launchAtLoginController: LaunchAtLoginController,
        smartHelperManager: SMARTHelperManager,
        onInstallOrUpdateHelper: @escaping () -> Void,
        onRefreshHelperStatus: @escaping () -> Void,
        canCheckForUpdates: @escaping () -> Bool,
        onCheckForUpdates: @escaping () -> Void,
        application: any SettingsApplicationProviding = LiveSettingsApplication()
    ) {
        self.application = application
        makeWindowController = {
            SettingsWindowController(
                settings: settings,
                launchAtLoginController: launchAtLoginController,
                smartHelperManager: smartHelperManager,
                onInstallOrUpdateHelper: onInstallOrUpdateHelper,
                onRefreshHelperStatus: onRefreshHelperStatus,
                canCheckForUpdates: canCheckForUpdates,
                onCheckForUpdates: onCheckForUpdates
            )
        }
    }

    init(
        application: any SettingsApplicationProviding,
        makeWindowController: @escaping @MainActor () -> any SettingsWindowPresenting
    ) {
        self.application = application
        self.makeWindowController = makeWindowController
    }

    func open() {
        application.setActivationPolicy(.regular)
        application.activate()

        let windowController = windowController ?? makeSettingsWindowController()
        windowController.present()
    }

    private func makeSettingsWindowController() -> any SettingsWindowPresenting {
        let controller = makeWindowController()
        controller.onClose = { [weak self] in
            self?.application.setActivationPolicy(.accessory)
        }
        windowController = controller
        return controller
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, SettingsWindowPresenting {
    static let contentWidth: CGFloat = 400
    static let minimumContentHeight: CGFloat = 450

    private let settings: AppSettings
    private let launchAtLoginController: LaunchAtLoginController
    private let smartHelperManager: SMARTHelperManager
    private let onInstallOrUpdateHelper: () -> Void
    private let onRefreshHelperStatus: () -> Void
    private let canCheckForUpdates: () -> Bool
    private let onCheckForUpdates: () -> Void
    private let settingsToolbar = NSToolbar(identifier: "palmos-settings")
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private var resizeGeneration = 0
    private(set) var selectedCategory = SettingsCategory.general
    private(set) var categoryItems: [SettingsCategory: NSToolbarItem] = [:]
    var onClose: (() -> Void)?

    init(
        settings: AppSettings,
        launchAtLoginController: LaunchAtLoginController,
        smartHelperManager: SMARTHelperManager,
        onInstallOrUpdateHelper: @escaping () -> Void,
        onRefreshHelperStatus: @escaping () -> Void,
        canCheckForUpdates: @escaping () -> Bool,
        onCheckForUpdates: @escaping () -> Void
    ) {
        self.settings = settings
        self.launchAtLoginController = launchAtLoginController
        self.smartHelperManager = smartHelperManager
        self.onInstallOrUpdateHelper = onInstallOrUpdateHelper
        self.onRefreshHelperStatus = onRefreshHelperStatus
        self.canCheckForUpdates = canCheckForUpdates
        self.onCheckForUpdates = onCheckForUpdates

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: Self.minimumContentHeight
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(
            width: Self.contentWidth,
            height: Self.minimumContentHeight
        )
        window.title = ""
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        configureToolbar(for: window)
        window.setContentSize(NSSize(
            width: Self.contentWidth,
            height: Self.minimumContentHeight
        ))
        showCategory(.general)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func selectCategory(_ category: SettingsCategory) {
        guard category != selectedCategory else { return }
        selectedCategory = category
        settingsToolbar.selectedItemIdentifier = category.toolbarItemIdentifier
        showCategory(category)
    }

    func present() {
        guard let window else { return }
        launchAtLoginController.refreshStatus()
        onRefreshHelperStatus()
        showCategory(selectedCategory)
        if window.isVisible == false {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    static func resolvedContentHeight(for fittingHeight: CGFloat) -> CGFloat {
        max(minimumContentHeight, fittingHeight)
    }

    private func configureToolbar(for window: NSWindow) {
        settingsToolbar.delegate = self
        settingsToolbar.displayMode = .iconAndLabel
        settingsToolbar.allowsUserCustomization = false
        settingsToolbar.autosavesConfiguration = false
        window.toolbarStyle = .preference
        window.toolbar = settingsToolbar
        window.titlebarSeparatorStyle = .none
        settingsToolbar.selectedItemIdentifier = selectedCategory.toolbarItemIdentifier
    }

    private func showCategory(_ category: SettingsCategory) {
        // Invalidate a deferred measurement from the previously hosted pane.
        resizeGeneration += 1
        hostingController.rootView = AnyView(
            SettingsView(
                category: category,
                settings: settings,
                launchAtLoginController: launchAtLoginController,
                smartHelperManager: smartHelperManager,
                onInstallOrUpdateHelper: onInstallOrUpdateHelper,
                onRefreshHelperStatus: onRefreshHelperStatus,
                canCheckForUpdates: canCheckForUpdates,
                onCheckForUpdates: onCheckForUpdates
            )
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { [weak self] height in
                self?.scheduleResize(toFit: height)
            }
        )
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.sizeThatFits(in: NSSize(
            width: Self.contentWidth,
            height: .greatestFiniteMagnitude
        ))
        resizeWindow(toFit: fittingSize.height)
    }

    private func scheduleResize(toFit fittingHeight: CGFloat) {
        resizeGeneration += 1
        let generation = resizeGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, generation == self.resizeGeneration else { return }
            self.resizeWindow(toFit: fittingHeight)
        }
    }

    private func resizeWindow(toFit fittingHeight: CGFloat) {
        guard let window, fittingHeight.isFinite, fittingHeight > 0 else { return }
        let contentHeight = Self.resolvedContentHeight(for: fittingHeight)
        guard let currentHeight = window.contentView?.bounds.height,
              abs(currentHeight - contentHeight) > 0.5 else { return }

        let oldFrame = window.frame
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: Self.contentWidth,
            height: contentHeight
        )
        var newFrame = window.frameRect(forContentRect: contentRect)
        newFrame.origin.x = oldFrame.origin.x
        newFrame.origin.y = oldFrame.maxY - newFrame.height
        window.setFrame(newFrame, display: true, animate: false)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

extension SettingsWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsCategory.allCases.map(\.toolbarItemIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let category = SettingsCategory(toolbarItemIdentifier: itemIdentifier) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = category.title
        item.paletteLabel = category.title
        item.toolTip = category.title
        item.image = NSImage(
            systemSymbolName: category.systemImage,
            accessibilityDescription: category.title
        )?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        item.target = self
        item.action = #selector(selectToolbarCategory(_:))
        item.tag = category.rawValue
        item.isBordered = false
        categoryItems[category] = item
        return item
    }

    @objc
    private func selectToolbarCategory(_ sender: NSToolbarItem) {
        guard let category = SettingsCategory(rawValue: sender.tag) else { return }
        selectCategory(category)
    }
}
