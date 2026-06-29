import DrivePulseCore
import Foundation

final class SmartctlRunner {
    enum RunnerError: LocalizedError {
        case invalidDeviceName(String)
        case executableNotFound
        case commandFailed(exitCode: Int32, transportHint: SmartctlTransportHint, output: String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case let .invalidDeviceName(deviceName):
                return "Unsupported SMART device name: \(deviceName)"
            case .executableNotFound:
                return "smartctl executable not found in supported install locations."
            case let .commandFailed(exitCode, transportHint, output):
                let hintDescription = transportHint.smartctlDeviceArgument ?? "default"
                return "smartctl failed with exit code \(exitCode) using transport hint \(hintDescription): \(output)"
            case .emptyOutput:
                return "smartctl returned no SMART payload."
            }
        }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func readSMARTData(
        for physicalDeviceBSDName: String,
        transportHint: SmartctlTransportHint
    ) throws -> Data {
        let sanitizedBSDName = try sanitize(physicalDeviceBSDName)

        let process = Process()
        process.executableURL = try smartctlExecutableURL()
        process.arguments = arguments(
            for: sanitizedBSDName,
            transportHint: transportHint
        )

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let stdoutReader = PipeReader(fileHandle: stdout.fileHandleForReading)
        let stderrReader = PipeReader(fileHandle: stderr.fileHandleForReading)
        stdoutReader.start()
        stderrReader.start()

        process.waitUntilExit()
        let stdoutData = stdoutReader.waitForData()
        let stderrData = stderrReader.waitForData()
        let combinedOutput = combinedOutput(stdout: stdoutData, stderr: stderrData)

        guard stdoutData.isEmpty == false else {
            guard process.terminationStatus == 0 else {
                throw RunnerError.commandFailed(
                    exitCode: process.terminationStatus,
                    transportHint: transportHint,
                    output: combinedOutput
                )
            }
            throw RunnerError.emptyOutput
        }

        guard process.terminationStatus == 0 || isValidJSONPayload(stdoutData) else {
            throw RunnerError.commandFailed(
                exitCode: process.terminationStatus,
                transportHint: transportHint,
                output: combinedOutput
            )
        }

        return stdoutData
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

    private func smartctlExecutableURL() throws -> URL {
        let candidatePaths = [
            "/opt/homebrew/sbin/smartctl",
            "/usr/local/sbin/smartctl",
            "/opt/homebrew/bin/smartctl",
            "/usr/local/bin/smartctl"
        ]

        for candidatePath in candidatePaths where fileManager.isExecutableFile(atPath: candidatePath) {
            return URL(fileURLWithPath: candidatePath)
        }

        throw RunnerError.executableNotFound
    }

    private func isValidJSONPayload(_ data: Data) -> Bool {
        guard data.isEmpty == false else {
            return false
        }

        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return true
        } catch {
            return false
        }
    }

    private func combinedOutput(stdout: Data, stderr: Data) -> String {
        var sections: [String] = []

        if stdout.isEmpty == false {
            sections.append(String(decoding: stdout, as: UTF8.self))
        }

        if stderr.isEmpty == false {
            sections.append(String(decoding: stderr, as: UTF8.self))
        }

        return sections.joined(separator: "\n")
    }
}

private final class PipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func start() {
        Thread.detachNewThread { [self] in
            let output = fileHandle.readDataToEndOfFile()
            lock.lock()
            data = output
            lock.unlock()
            semaphore.signal()
        }
    }

    func waitForData() -> Data {
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
