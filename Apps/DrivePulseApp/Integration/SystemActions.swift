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
        case openDiskUtility(bsdName: String)
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
        guard let device else {
            return [Self(kind: .quit, intent: .quit)]
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
                intent: .openDiskUtility(bsdName: device.physicalStoreBSDName)
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
    private let diskArbitration: any DiskArbitrationClient
    private let workspace: any WorkspaceClient
    private let actionQueue: DispatchQueue

    init(
        diskArbitration: any DiskArbitrationClient = LiveDiskArbitrationClient(),
        workspace: any WorkspaceClient = LiveWorkspaceClient(),
        actionQueue: DispatchQueue = DispatchQueue(label: "DrivePulse.SystemActions", qos: .userInitiated)
    ) {
        self.diskArbitration = diskArbitration
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
        case .ejectPhysicalDevice(let bsdName):
            try await runOnActionQueue {
                try diskArbitration.ejectWholeDisk(bsdName: bsdName)
            }
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
        try diskArbitration.volumeURL(for: bsdName)
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
    case diskNotFound
    case operationTimedOut
    case applicationNotFound
    case diskArbitrationFailed(status: DAReturn, message: String?)

    var errorDescription: String? {
        switch self {
        case .volumeNotMounted:
            return String(localized: "No mounted volume available.")
        case .diskNotFound:
            return String(localized: "Couldn't find that disk. It may have been disconnected or reassigned.")
        case .operationTimedOut:
            return String(localized: "Action timed out.")
        case .applicationNotFound:
            return String(localized: "Action couldn't be completed.")
        case .diskArbitrationFailed(let status, let message):
            // DiskArbitration's dissenter message is already a system-provided,
            // human-readable reason (e.g. "couldn't be unmounted because one or
            // more programs may be using it") — the same text Finder would show,
            // so surface it instead of a generic fallback. Some dissenters carry
            // a status but no message string, so fall back to a description of
            // the status code rather than a completely generic message.
            if let message, message.isEmpty == false {
                return message
            }
            return Self.description(for: status)
        }
    }

    private static func description(for status: DAReturn) -> String {
        switch status {
        case DAReturn(kDAReturnBusy):
            return String(localized: "The disk is busy — something may still be reading or writing to it.")
        case DAReturn(kDAReturnExclusiveAccess):
            return String(localized: "The disk couldn't be accessed exclusively — another process has it open.")
        case DAReturn(kDAReturnNotFound), DAReturn(kDAReturnNotMounted):
            return String(localized: "Couldn't find that disk. It may have been disconnected or reassigned.")
        case DAReturn(kDAReturnNotPermitted), DAReturn(kDAReturnNotPrivileged):
            return String(localized: "DrivePulse doesn't have permission to complete this action.")
        case DAReturn(kDAReturnNotReady):
            return String(localized: "The disk isn't ready yet — try again in a moment.")
        default:
            return String(
                format: String(localized: "Action couldn't be completed (status 0x%08X)."),
                UInt32(bitPattern: status)
            )
        }
    }
}

protocol DiskArbitrationClient: Sendable {
    func volumeURL(for bsdName: String) throws -> URL
    func ejectWholeDisk(bsdName: String) throws
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

private final class LiveDiskArbitrationClient: DiskArbitrationClient, @unchecked Sendable {
    // Matches the QoS of the `actionQueue` thread that blocks on
    // `waitForCompletion`, so the DiskArbitration completion callback isn't
    // scheduled at a lower priority than the thread waiting on it (Thread
    // Performance Checker flags this as a priority inversion otherwise).
    private let sessionQueue = DispatchQueue(label: "DrivePulse.SystemActions.DiskArbitration", qos: .userInitiated)
    private let operationTimeout: DispatchTimeInterval

    init(operationTimeout: DispatchTimeInterval = .seconds(10)) {
        self.operationTimeout = operationTimeout
    }

    func volumeURL(for bsdName: String) throws -> URL {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = createDisk(bsdName: bsdName, session: session),
              let description = DADiskCopyDescription(disk) as? [String: Any],
              let volumeURL = description[kDADiskDescriptionVolumePathKey as String] as? URL else {
            throw SystemActionError.volumeNotMounted
        }

        return volumeURL
    }

    func ejectWholeDisk(bsdName: String) throws {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = createDisk(bsdName: bsdName, session: session) else {
            throw SystemActionError.diskNotFound
        }

        DASessionSetDispatchQueue(session, sessionQueue)
        defer {
            DASessionSetDispatchQueue(session, nil)
        }

        try performDiskOperation(ignoringStatuses: [DAReturn(kDAReturnNotMounted)]) { context in
            DADiskUnmount(
                disk,
                DADiskUnmountOptions(kDADiskUnmountOptionWhole),
                diskArbitrationUnmountCallback,
                context
            )
        }
        try performDiskOperation { context in
            DADiskEject(
                disk,
                DADiskEjectOptions(kDADiskEjectOptionDefault),
                diskArbitrationEjectCallback,
                context
            )
        }
    }

    private func createDisk(bsdName: String, session: DASession) -> DADisk? {
        bsdName.withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
    }

    private func performDiskOperation(
        ignoringStatuses: Set<DAReturn> = [],
        operation: (UnsafeMutableRawPointer) -> Void
    ) throws {
        let completion = DiskArbitrationCompletion(ignoringStatuses: ignoringStatuses)
        let context = Unmanaged.passRetained(completion).toOpaque()
        operation(context)
        try completion.waitForCompletion(timeout: operationTimeout)
    }
}

final class DiskArbitrationCompletion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let ignoringStatuses: Set<DAReturn>
    private var result: Result<Void, Error> = .success(())

    init(ignoringStatuses: Set<DAReturn>) {
        self.ignoringStatuses = ignoringStatuses
    }

    func finish(with dissenter: DADissenter?) {
        if let dissenter {
            let status = DADissenterGetStatus(dissenter)
            if ignoringStatuses.contains(status) == false {
                let message = DADissenterGetStatusString(dissenter) as String?
                result = .failure(SystemActionError.diskArbitrationFailed(status: status, message: message))
            }
        }

        semaphore.signal()
    }

    func waitForCompletion(timeout: DispatchTimeInterval = .seconds(10)) throws {
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        guard waitResult == .success else {
            throw SystemActionError.operationTimedOut
        }

        try result.get()
    }
}

private let diskArbitrationUnmountCallback: DADiskUnmountCallback = { _, dissenter, context in
    completeDiskArbitrationOperation(dissenter: dissenter, context: context)
}

private let diskArbitrationEjectCallback: DADiskEjectCallback = { _, dissenter, context in
    completeDiskArbitrationOperation(dissenter: dissenter, context: context)
}

private func completeDiskArbitrationOperation(
    dissenter: DADissenter?,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }

    let completion = Unmanaged<DiskArbitrationCompletion>.fromOpaque(context).takeRetainedValue()
    completion.finish(with: dissenter)
}
