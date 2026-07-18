import Darwin
import DrivePulseCore
import Foundation

protocol SMARTDataRunning: Sendable {
    /// Returns or throws only after the child has exited (or when no child was
    /// launched). The completion envelope relies on this terminal guarantee.
    func readSMARTData(
        for physicalDeviceBSDName: String,
        transportHint: SmartctlTransportHint,
        timeout: Duration
    ) async throws -> Data

    func isCompanionAvailable() -> Bool
}

final class SmartctlRunner: SMARTDataRunning, @unchecked Sendable {
    enum RunnerError: LocalizedError, Equatable {
        case invalidDeviceName(String)
        case executableUnavailable
        case commandFailed(exitCode: Int32, transportHint: SmartctlTransportHint, output: String)
        case emptyOutput
        case outputTooLarge
        case timedOut

        var errorDescription: String? {
            switch self {
            case let .invalidDeviceName(deviceName):
                return "Unsupported SMART device name: \(deviceName)"
            case .executableUnavailable:
                return "SMART monitoring is unavailable because the trusted smartctl companion is not installed."
            case let .commandFailed(exitCode, transportHint, output):
                let hintDescription = transportHint.smartctlDeviceArgument ?? "default"
                return "smartctl failed with exit code \(exitCode) using transport hint \(hintDescription): \(output)"
            case .emptyOutput:
                return "smartctl returned no SMART payload."
            case .outputTooLarge:
                return "smartctl returned a SMART payload that exceeded the configured safety limit."
            case .timedOut:
                return "smartctl did not finish before the SMART operation deadline."
            }
        }
    }

    static let defaultTimeout: Duration = .seconds(20)
    static let stdoutLimit = 2 * 1024 * 1024
    static let stderrLimit = 64 * 1024
    static let trustedExecutablePath = "/Library/PrivilegedHelperTools/com.drivepulse.smartservice.smartctl"
    static let trustedExecutableIdentifier = "com.drivepulse.smartservice.smartctl"

    private let executableLocator: @Sendable () throws -> URL

    init(
        executableLocator: @escaping @Sendable () throws -> URL = SmartctlRunner.trustedExecutable
    ) {
        self.executableLocator = executableLocator
    }

    func readSMARTData(
        for physicalDeviceBSDName: String,
        transportHint: SmartctlTransportHint,
        timeout: Duration = SmartctlRunner.defaultTimeout
    ) async throws -> Data {
        let sanitizedBSDName = try sanitize(physicalDeviceBSDName)
        let process = Process()
        let controller = RunningProcess(process)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            do {
                process.executableURL = try executableLocator()
            } catch {
                try Task.checkCancellation()
                throw RunnerError.executableUnavailable
            }
            try Task.checkCancellation()

            process.arguments = arguments(
                for: sanitizedBSDName,
                transportHint: transportHint
            )

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let stdoutReader = BoundedPipeReader(stdout.fileHandleForReading, limit: Self.stdoutLimit)
            let stderrReader = BoundedPipeReader(stderr.fileHandleForReading, limit: Self.stderrLimit)
            try controller.launch()

            async let stdoutResult = stdoutReader.read()
            async let stderrResult = stderrReader.read()

            let deadline = ContinuousClock.now.advanced(by: timeout)
            let monitor = Task {
                while controller.isRunning {
                    if ContinuousClock.now >= deadline {
                        controller.terminateForTimeout()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            await controller.waitForExit()
            monitor.cancel()

            let stdoutData = await stdoutResult
            let stderrData = await stderrResult
            if controller.didTimeOut {
                throw RunnerError.timedOut
            }
            try Task.checkCancellation()
            guard stdoutReader.exceededLimit == false, stderrReader.exceededLimit == false else {
                throw RunnerError.outputTooLarge
            }

            let combined = Self.combinedOutput(stdout: stdoutData, stderr: stderrData)
            guard stdoutData.isEmpty == false else {
                guard process.terminationStatus == 0 else {
                    throw RunnerError.commandFailed(
                        exitCode: process.terminationStatus,
                        transportHint: transportHint,
                        output: combined
                    )
                }
                throw RunnerError.emptyOutput
            }

            guard process.terminationStatus == 0 || Self.isValidJSONPayload(stdoutData) else {
                throw RunnerError.commandFailed(
                    exitCode: process.terminationStatus,
                    transportHint: transportHint,
                    output: combined
                )
            }
            return stdoutData
        } onCancel: {
            controller.requestTermination()
        }
    }

    func isCompanionAvailable() -> Bool {
        (try? executableLocator()) != nil
    }

    private func sanitize(_ physicalDeviceBSDName: String) throws -> String {
        guard physicalDeviceBSDName.range(
            of: #"^disk\d+$"#,
            options: .regularExpression
        ) != nil else {
            throw RunnerError.invalidDeviceName(physicalDeviceBSDName)
        }
        return physicalDeviceBSDName
    }

    private func arguments(
        for physicalDeviceBSDName: String,
        transportHint: SmartctlTransportHint
    ) -> [String] {
        var arguments = ["-a", "-j", "--nocheck=standby"]
        if let deviceArgument = transportHint.smartctlDeviceArgument {
            arguments.append(contentsOf: ["-d", deviceArgument])
        }
        arguments.append("/dev/\(physicalDeviceBSDName)")
        return arguments
    }

    private static func trustedExecutable() throws -> URL {
        let url = URL(fileURLWithPath: trustedExecutablePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard
            FileManager.default.isExecutableFile(atPath: url.path),
            (attributes[.type] as? FileAttributeType) == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
            permissions & 0o022 == 0
        else {
            throw RunnerError.executableUnavailable
        }
        var parent = url.deletingLastPathComponent()
        while true {
            let parentAttributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard
                (parentAttributes[.type] as? FileAttributeType) == .typeDirectory,
                (parentAttributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                let parentPermissions = (parentAttributes[.posixPermissions] as? NSNumber)?.intValue,
                parentPermissions & 0o022 == 0
            else {
                throw RunnerError.executableUnavailable
            }
            if parent.path == "/" { break }
            parent.deleteLastPathComponent()
        }
        do {
            try SecuritySMARTCompanionCodeValidator().validateCompanion(at: url)
        } catch {
            throw RunnerError.executableUnavailable
        }
        return url
    }

    private static func isValidJSONPayload(_ data: Data) -> Bool {
        guard data.isEmpty == false else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func combinedOutput(stdout: Data, stderr: Data) -> String {
        var sections: [String] = []
        if stdout.isEmpty == false { sections.append(String(decoding: stdout, as: UTF8.self)) }
        if stderr.isEmpty == false { sections.append(String(decoding: stderr, as: UTF8.self)) }
        let output = sections.joined(separator: "\n")
        return String(output.prefix(8_192))
    }
}

private final class RunningProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false
    private var terminationRequested = false

    init(_ process: Process) { self.process = process }
    var isRunning: Bool { lock.withLock { process.isRunning } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    func launch() throws {
        try lock.withLock {
            guard terminationRequested == false else {
                throw CancellationError()
            }
            try process.run()
        }
    }

    func terminateForTimeout() {
        lock.withLock {
            timedOut = true
            terminationRequested = true
            if process.isRunning { process.terminate() }
        }
        scheduleKill()
    }

    func requestTermination() {
        lock.withLock {
            terminationRequested = true
            if process.isRunning { process.terminate() }
        }
        scheduleKill()
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [process] in
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func scheduleKill() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
            lock.withLock {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

private final class BoundedPipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let limit: Int
    private let lock = NSLock()
    private var overflow = false

    init(_ fileHandle: FileHandle, limit: Int) {
        self.fileHandle = fileHandle
        self.limit = limit
    }

    var exceededLimit: Bool { lock.withLock { overflow } }

    func read() async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [self] in
                var stored = Data()
                while true {
                    let chunk = fileHandle.readData(ofLength: 64 * 1024)
                    guard chunk.isEmpty == false else { break }
                    let remaining = max(0, limit - stored.count)
                    stored.append(chunk.prefix(remaining))
                    if chunk.count > remaining { lock.withLock { overflow = true } }
                }
                continuation.resume(returning: stored)
            }
        }
    }
}
