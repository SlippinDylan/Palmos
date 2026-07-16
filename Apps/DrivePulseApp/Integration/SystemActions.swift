import AppKit
import DiskArbitration
import Foundation

import DrivePulseCore

struct SystemAction: Identifiable, Equatable {
    enum Kind: String {
        case openInFinder
        case eject
        case openDiskUtility
        case quit
    }

    enum Intent: Equatable {
        case revealInFinder(volumeBSDName: String)
        case ejectPhysicalDevice(bsdName: String)
        case openDiskUtility
        case quit
    }

    let kind: Kind
    let intent: Intent

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .openInFinder:
            return String(localized: "Open in Finder")
        case .eject:
            return String(localized: "Eject Disk")
        case .openDiskUtility:
            return String(localized: "Disk Utility")
        case .quit:
            return String(localized: "Quit")
        }
    }

    var footerTitle: String {
        switch kind {
        case .openInFinder:
            return String(localized: "Finder")
        case .eject:
            return String(localized: "Eject")
        case .openDiskUtility:
            return String(localized: "Disk Utility")
        case .quit:
            return String(localized: "Quit")
        }
    }

    var systemImageName: String {
        switch kind {
        case .openInFinder:
            return "folder"
        case .eject:
            return "eject"
        case .openDiskUtility:
            return "internaldrive"
        case .quit:
            return "power"
        }
    }

    var successFeedbackMessage: String {
        switch kind {
        case .openInFinder:
            return String(localized: "Opened in Finder.")
        case .eject:
            return String(localized: "Ejected disk.")
        case .openDiskUtility:
            return String(localized: "Opened Disk Utility.")
        case .quit:
            return String(localized: "Quitting DrivePulse…")
        }
    }

    /// Whether dispatching this action should dismiss the menu bar panel so
    /// the window it opens (Finder, Disk Utility) is what ends up in front,
    /// instead of competing with the still-open panel for focus.
    var dismissesMenuBarPanelOnDispatch: Bool {
        switch kind {
        case .openInFinder, .openDiskUtility:
            return true
        case .eject, .quit:
            return false
        }
    }

    static func footerActions(for device: ExternalDevice?) -> [Self] {
        guard let device, device.volumes.isEmpty == false else {
            return [
                Self(kind: .openDiskUtility, intent: .openDiskUtility),
                Self(kind: .quit, intent: .quit)
            ]
        }

        var actions: [Self] = []

        if let mountedVolume = device.volumes.first {
            actions.append(
                Self(
                    kind: .openInFinder,
                    intent: .revealInFinder(volumeBSDName: mountedVolume.bsdName)
                )
            )
        }

        actions.append(
            Self(
                kind: .eject,
                intent: .ejectPhysicalDevice(bsdName: device.physicalStoreBSDName)
            )
        )
        actions.append(
            Self(
                kind: .openDiskUtility,
                intent: .openDiskUtility
            )
        )
        actions.append(Self(kind: .quit, intent: .quit))
        return actions
    }
}

protocol SystemActionPerforming: Sendable {
    func perform(_ action: SystemAction) async throws
}

struct SystemActions: SystemActionPerforming {
    private let volumeLocator: any DiskVolumeLocating
    private let workspace: any WorkspaceClient
    private let actionQueue: DispatchQueue

    init(
        diskArbitration: any DiskVolumeLocating = LiveDiskVolumeLocator(),
        workspace: any WorkspaceClient = LiveWorkspaceClient(),
        actionQueue: DispatchQueue = DispatchQueue(label: "DrivePulse.SystemActions", qos: .userInitiated)
    ) {
        self.volumeLocator = diskArbitration
        self.workspace = workspace
        self.actionQueue = actionQueue
    }

    func perform(_ action: SystemAction) async throws {
        switch action.intent {
        case .revealInFinder(let volumeBSDName):
            let volumeURL = try await runOnActionQueue {
                try mountedVolumeURL(for: volumeBSDName)
            }
            await workspace.reveal([volumeURL])
        case .ejectPhysicalDevice:
            return
        case .openDiskUtility:
            // Passing /dev/diskN as a target causes Launch Services to show a
            // "no permission" dialog, so Disk Utility is opened as a plain
            // application launch instead of pointing it at a specific disk.
            try await workspace.openApplication(bundleIdentifier: "com.apple.DiskUtility")
        case .quit:
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func mountedVolumeURL(for bsdName: String) throws -> URL {
        try volumeLocator.volumeURL(for: bsdName)
    }

    private func runOnActionQueue<T>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            actionQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum SystemActionError: LocalizedError {
    case volumeNotMounted
    case applicationNotFound

    var errorDescription: String? {
        switch self {
        case .volumeNotMounted:
            return String(localized: "No mounted volume available.")
        case .applicationNotFound:
            return String(localized: "Action couldn't be completed.")
        }
    }
}

protocol DiskVolumeLocating: Sendable {
    func volumeURL(for bsdName: String) throws -> URL
}

protocol WorkspaceClient: Sendable {
    @MainActor
    func reveal(_ urls: [URL]) async

    @MainActor
    func openApplication(bundleIdentifier: String) async throws
}

private struct LiveWorkspaceClient: WorkspaceClient {
    @MainActor
    func reveal(_ urls: [URL]) async {
        // The app runs with an accessory activation policy (no Dock icon), so
        // without an explicit activate() the window server can leave Finder's
        // reveal noticeably slow to come forward.
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @MainActor
    func openApplication(bundleIdentifier: String) async throws {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            throw SystemActionError.applicationNotFound
        }

        NSApp.activate(ignoringOtherApps: true)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private final class LiveDiskVolumeLocator: DiskVolumeLocating, @unchecked Sendable {
    func volumeURL(for bsdName: String) throws -> URL {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = createDisk(bsdName: bsdName, session: session),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let volumeURL = description[kDADiskDescriptionVolumePathKey as String] as? URL else {
            throw SystemActionError.volumeNotMounted
        }

        return volumeURL
    }

    private func createDisk(bsdName: String, session: DASession) -> DADisk? {
        bsdName.withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
    }
}
