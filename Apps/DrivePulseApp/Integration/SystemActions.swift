import AppKit
import DiskArbitration
import Foundation

import DrivePulseCore

struct SystemAction: Identifiable, Equatable {
    enum Kind: String {
        case openInFinder
        case eject
        case openDiskUtility
        case settings
    }

    enum Intent: Equatable {
        case revealInFinder(volumeBSDName: String)
        case ejectPhysicalDevice(bsdName: String)
        case openDiskUtility(bsdName: String)
        case openSettings
    }

    let kind: Kind
    let intent: Intent

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .openInFinder:
            return String(localized: "Open in Finder")
        case .eject:
            return String(localized: "Eject")
        case .openDiskUtility:
            return String(localized: "Disk Utility")
        case .settings:
            return String(localized: "Settings")
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
        case .settings:
            return "gearshape"
        }
    }

    static func actions(for device: ExternalDevice?) -> [Self] {
        guard let device else {
            return [Self(kind: .settings, intent: .openSettings)]
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
        actions.append(Self(kind: .settings, intent: .openSettings))
        return actions
    }
}

struct SystemActions {
    private let diskArbitration: any DiskArbitrationClient
    private let workspace: any WorkspaceClient
    private let commandRunner: any CommandRunner

    init(
        diskArbitration: any DiskArbitrationClient = LiveDiskArbitrationClient(),
        workspace: any WorkspaceClient = LiveWorkspaceClient(),
        commandRunner: any CommandRunner = ProcessCommandRunner()
    ) {
        self.diskArbitration = diskArbitration
        self.workspace = workspace
        self.commandRunner = commandRunner
    }

    func perform(_ action: SystemAction) throws {
        switch action.intent {
        case .revealInFinder(let volumeBSDName):
            let volumeURL = try mountedVolumeURL(for: volumeBSDName)
            workspace.reveal([volumeURL])
        case .ejectPhysicalDevice(let bsdName):
            try diskArbitration.ejectWholeDisk(bsdName: bsdName)
        case .openDiskUtility(let bsdName):
            _ = try commandRunner.run(
                "/usr/bin/open",
                arguments: ["-b", "com.apple.DiskUtility", "/dev/\(bsdName)"]
            )
        case .openSettings:
            break
        }
    }

    private func mountedVolumeURL(for bsdName: String) throws -> URL {
        try diskArbitration.volumeURL(for: bsdName)
    }
}

private enum SystemActionError: LocalizedError {
    case volumeNotMounted
    case diskNotFound
    case commandFailed(message: String?)
    case diskArbitrationFailed(status: DAReturn, message: String?)

    var errorDescription: String? {
        switch self {
        case .volumeNotMounted:
            return String(localized: "No mounted volume available.")
        case .diskNotFound:
            return String(localized: "Action couldn't be completed.")
        case .commandFailed:
            return String(localized: "Action couldn't be completed.")
        case .diskArbitrationFailed:
            return String(localized: "Action couldn't be completed.")
        }
    }
}

protocol DiskArbitrationClient {
    func volumeURL(for bsdName: String) throws -> URL
    func ejectWholeDisk(bsdName: String) throws
}

protocol WorkspaceClient {
    func reveal(_ urls: [URL])
}

protocol CommandRunner {
    func run(_ executablePath: String, arguments: [String]) throws -> Data
}

private struct LiveWorkspaceClient: WorkspaceClient {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private struct ProcessCommandRunner: CommandRunner {
    @discardableResult
    func run(_ executablePath: String, arguments: [String]) throws -> Data {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput.isEmpty ? output : errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            throw SystemActionError.commandFailed(message: message)
        }

        return output
    }
}

private final class LiveDiskArbitrationClient: DiskArbitrationClient {
    private let sessionQueue = DispatchQueue(label: "DrivePulse.SystemActions.DiskArbitration")

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
        try completion.waitForCompletion()
    }
}

private final class DiskArbitrationCompletion {
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

    func waitForCompletion() throws {
        semaphore.wait()
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
