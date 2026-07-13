import Foundation

final class HelperOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct HelperTopologyCommandRunner: Sendable {
    private static let outputLimit = 2 * 1024 * 1024
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/diskutil")) {
        self.executableURL = executableURL
    }

    func propertyList(
        arguments: [String],
        deadline: ContinuousClock.Instant,
        cancellation: HelperOperationCancellation
    ) async throws -> [String: Any]? {
        let data = try await run(arguments: arguments, deadline: deadline, cancellation: cancellation)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    func run(
        arguments: [String],
        deadline: ContinuousClock.Instant,
        cancellation: HelperOperationCancellation
    ) async throws -> Data {
        guard !cancellation.isCancelled, ContinuousClock.now < deadline else {
            throw CancellationError()
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let processBox = RunningTopologyProcess(process)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        let stdoutReader = BoundedTopologyPipeReader(stdout.fileHandleForReading, limit: Self.outputLimit)
        let stderrReader = BoundedTopologyPipeReader(stderr.fileHandleForReading, limit: Self.outputLimit)
        return try await withTaskCancellationHandler {
            try process.run()
            async let stdoutData = stdoutReader.read()
            async let stderrData = stderrReader.read()
            let monitor = Task.detached {
                while processBox.isRunning {
                    if cancellation.isCancelled || ContinuousClock.now >= deadline {
                        processBox.terminate()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            await processBox.waitForExit()
            monitor.cancel()
            let output = await stdoutData
            _ = await stderrData

            guard !cancellation.isCancelled, ContinuousClock.now < deadline else {
                throw CancellationError()
            }
            guard process.terminationStatus == 0, !stdoutReader.exceededLimit else {
                return Data()
            }
            return output
        } onCancel: {
            processBox.terminate()
        }
    }
}

private final class RunningTopologyProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    init(_ process: Process) { self.process = process }
    var isRunning: Bool { lock.withLock { process.isRunning } }
    func terminate() { lock.withLock { if process.isRunning { process.terminate() } } }
    func waitForExit() async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { [process] in
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

private final class BoundedTopologyPipeReader: @unchecked Sendable {
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
                    guard !chunk.isEmpty else { break }
                    let remaining = max(0, limit - stored.count)
                    stored.append(chunk.prefix(remaining))
                    if chunk.count > remaining {
                        lock.withLock { overflow = true }
                    }
                }
                continuation.resume(returning: stored)
            }
        }
    }
}
