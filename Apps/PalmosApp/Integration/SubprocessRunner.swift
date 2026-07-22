import Foundation

import Darwin

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ newValue: Data) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum SubprocessRunner {
    static let defaultMaxOutputBytes = 4 * 1024 * 1024
    static let defaultTimeout: Duration = .seconds(30)

    static func run(
        executable: String,
        arguments: [String],
        maxOutputBytes: Int = defaultMaxOutputBytes,
        timeout: Duration = defaultTimeout,
        processPrepared: (@Sendable () -> Void)? = nil
    ) async -> Data? {
        guard maxOutputBytes > 0 else { return nil }
        let processBox = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process()
                    processBox.set(process)
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    processPrepared?()

                    do {
                        try process.run()
                        processBox.processDidStart(process)
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }

                    let timeoutWorkItem = DispatchWorkItem {
                        processBox.terminateAndEscalate()
                    }
                    let timeoutNanoseconds = timeout.nanosecondsClamped
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + .nanoseconds(timeoutNanoseconds),
                        execute: timeoutWorkItem
                    )

                    let readQueue = DispatchQueue(label: "Palmos.SubprocessRunner.read", attributes: .concurrent)
                    let group = DispatchGroup()
                    let stdoutBox = DataBox()
                    let stderrBox = DataBox()

                    group.enter()
                    readQueue.async {
                        stdoutBox.set(readData(
                            from: stdoutPipe.fileHandleForReading,
                            maxBytes: maxOutputBytes,
                            processBox: processBox
                        ))
                        group.leave()
                    }

                    group.enter()
                    readQueue.async {
                        stderrBox.set(readData(
                            from: stderrPipe.fileHandleForReading,
                            maxBytes: maxOutputBytes,
                            processBox: processBox
                        ))
                        group.leave()
                    }

                    process.waitUntilExit()
                    group.wait()
                    timeoutWorkItem.cancel()
                    let stdoutData = stdoutBox.get()
                    let stderrData = stderrBox.get()
                    let succeeded = processBox.isCancelled == false
                        && process.terminationReason == .exit
                        && process.terminationStatus == 0
                    if stdoutData.isEmpty,
                       stderrData.isEmpty == false,
                       processBox.isCancelled == false {
                        let stderrMessage = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if let stderrMessage, stderrMessage.isEmpty == false {
                            NSLog(
                                "[SubprocessRunner] %@ %@ failed (exit %d): %@",
                                executable,
                                arguments.joined(separator: " "),
                                process.terminationStatus,
                                stderrMessage
                            )
                        }
                    }
                    continuation.resume(
                        returning: succeeded && stdoutData.isEmpty == false ? stdoutData : nil
                    )
                    processBox.clear(process)
                }
            }
        } onCancel: {
            processBox.terminateAndEscalate()
        }
    }

    private static func readData(
        from fileHandle: FileHandle,
        maxBytes: Int,
        processBox: ProcessBox
    ) -> Data {
        var output = Data()
        output.reserveCapacity(min(maxBytes, 64 * 1024))
        while output.count <= maxBytes {
            let chunk = fileHandle.readData(ofLength: min(64 * 1024, maxBytes + 1 - output.count))
            guard chunk.isEmpty == false else { break }
            output.append(chunk)
            if output.count > maxBytes {
                processBox.terminateAndEscalate()
                return Data()
            }
        }
        return output
    }
}

private extension Duration {
    var nanosecondsClamped: Int {
        let components = self.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        guard seconds >= 0 else { return 0 }
        let secondsPart = min(seconds, Int64(Int.max) / 1_000_000_000)
        let fractionalPart = min(attoseconds / 1_000_000_000, Int64(Int.max))
        let combined = secondsPart.multipliedReportingOverflow(by: 1_000_000_000)
        guard combined.overflow == false else { return Int.max }
        let result = combined.partialValue.addingReportingOverflow(fractionalPart)
        return result.overflow ? Int.max : Int(result.partialValue)
    }
}

final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false

    var isCancelled: Bool { lock.withLock { wasCancelled } }

    func set(_ process: Process) {
        let shouldTerminate = lock.withLock {
            self.process = process
            return wasCancelled
        }
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func clear(_ process: Process) {
        lock.withLock {
            if self.process === process { self.process = nil }
        }
    }

    func processDidStart(_ process: Process) {
        let shouldTerminate = lock.withLock { wasCancelled && self.process === process }
        if shouldTerminate { terminateAndEscalate() }
    }

    func terminate() {
        lock.withLock {
            wasCancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }

    func terminateAndEscalate() {
        let runningProcess: Process? = lock.withLock {
            wasCancelled = true
            guard let process, process.isRunning else { return nil }
            process.terminate()
            return process
        }
        guard let runningProcess else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self, weak runningProcess] in
            guard let self, let runningProcess else { return }
            self.killIfStillRunning(runningProcess)
        }
    }

    private func killIfStillRunning(_ expectedProcess: Process) {
        lock.withLock {
            guard process === expectedProcess, expectedProcess.isRunning else { return }
            _ = kill(expectedProcess.processIdentifier, SIGKILL)
        }
    }
}
